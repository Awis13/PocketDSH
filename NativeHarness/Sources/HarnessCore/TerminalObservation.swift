import Foundation

/// One shell command lifecycle record. `endedAt == nil` means the command
/// started but has not reported a prompt/exit status yet, so it is still open.
/// A record with `command == nil` is the standalone initial prompt that arrives
/// before any command has run; it has no measured duration.
public struct TerminalCommand: Codable, Sendable, Equatable {
    public let seq: Int64
    public let command: String?
    public let directory: String?
    public let exitCode: Int?
    public let startedAt: Date?
    public let endedAt: Date?
    public init(seq: Int64, command: String?, directory: String?, exitCode: Int?, startedAt: Date?, endedAt: Date?) {
        self.seq = seq; self.command = command; self.directory = directory
        self.exitCode = exitCode; self.startedAt = startedAt; self.endedAt = endedAt
    }
}

/// What a model wait is waiting for. `bytes` is the original behavior; the
/// lifecycle conditions only complete on new shell frames, never on output.
/// `exit` and `timeout` are result-only outcomes: they explain why a wait
/// ended and can never be requested as a condition.
public enum TerminalWaitCondition: String, Codable, Sendable, CaseIterable {
    case bytes
    case commandFinished = "command_finished"
    case cwdChanged = "cwd_changed"
    case exit
    case timeout

    /// The conditions a caller may request from `terminal_wait`.
    public static let requestable: Set<TerminalWaitCondition> = [.bytes, .commandFinished, .cwdChanged]
    public var isRequestable: Bool { Self.requestable.contains(self) }
}
public struct TerminalInfo: Codable, Sendable {
    public let id: String
    public let initialWorkspace: String
    public let firstCursor: Int64
    public let latestCursor: Int64
    public let retainedBytes: Int
    public let pendingWaits: Int
    public let exit: PTYExit?
    /// Foreground process group of the PTY, or nil when no shell is attached
    /// or the PTY is closed. This is the only foreground signal reported:
    /// exact "stdin waiting" is unavailable on macOS and DSH hardcodes it false.
    public let foregroundPgid: Int32?
    /// True only when a known foreground group differs from the shell's own
    /// group. Nil when either group is unknown: during the post-`forkpty`
    /// window before the child owns the terminal, or after the PTY closes.
    /// An unknown group is never reported as idle.
    public let foregroundBusy: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, initialWorkspace, firstCursor, latestCursor, retainedBytes, pendingWaits, exit
        case foregroundPgid, foregroundBusy
    }

    /// The documented wire shape promises an explicit `null` for an unknown
    /// `foregroundBusy`, but synthesized `Codable` omits nil optionals. Encode
    /// the key unconditionally so the JSON matches the docs; `foregroundPgid`
    /// keeps its existing omit-when-nil behavior. Decoding stays synthesized and
    /// therefore tolerant of a missing or null key.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(initialWorkspace, forKey: .initialWorkspace)
        try container.encode(firstCursor, forKey: .firstCursor)
        try container.encode(latestCursor, forKey: .latestCursor)
        try container.encode(retainedBytes, forKey: .retainedBytes)
        try container.encode(pendingWaits, forKey: .pendingWaits)
        try container.encodeIfPresent(exit, forKey: .exit)
        try container.encodeIfPresent(foregroundPgid, forKey: .foregroundPgid)
        try container.encode(foregroundBusy, forKey: .foregroundBusy)
    }
}

public struct TerminalRead: Codable, Sendable {
    public let terminalID: String
    public let startCursor: Int64
    public let nextCursor: Int64
    public let latestCursor: Int64
    public let gap: Bool
    public let bytes: Data
    /// Lossy convenience preview. bytes/base64 is canonical, including split UTF-8.
    public let text: String
    public let exit: PTYExit?
    public let timedOut: Bool
    /// Why the wait returned: bytes, exit, timeout, command_finished or
    /// cwd_changed. Nil for a plain `read`. A retention gap closes a `bytes`
    /// wait only; lifecycle waits are never woken by byte cursor movement.
    public let condition: TerminalWaitCondition?
    /// The command record that satisfied a `command_finished` wait.
    public let command: TerminalCommand?
    /// The directory that satisfied a `cwd_changed` wait (or the command's cwd).
    public let cwd: String?
}

/// Synchronous capture preserves PTY byte order without one unbounded Task per
/// output chunk. The lock covers capture and wait registration to avoid lost wakeups.
public final class TerminalObservation: @unchecked Sendable {
    public let id: String
    public let initialWorkspace: String
    private let capacity: Int
    private static let maxCommands = 64
    private static let maxCommandBytes = 4096
    private static let maxDirectoryBytes = 4096
    private let lock = NSLock()
    private var bytes = Data()
    private var end: Int64 = 0
    private var exit: PTYExit?
    private var commands: [TerminalCommand] = []
    private var commandSeq: Int64 = 0
    /// Pairing token of the start currently awaiting its matching ready: the
    /// `seq` stamped by `recordStart`. Nil when no start is open to a ready,
    /// either because the last one was completed, superseded, or invalidated by
    /// a known marker loss.
    private var openPairToken: Int64?
    private var finishedCommands: Int64 = 0
    private var cwdChanges: Int64 = 0
    private var latestDirectory: String
    private var shellPgid: Int32 = -1
    private var foreground: (@Sendable () -> Int32?)?
    private struct Waiter {
        let cursor: Int64
        let limit: Int
        let condition: TerminalWaitCondition
        let baseline: Int64
        let continuation: CheckedContinuation<TerminalRead, any Error>
        let timer: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    public init(id: String, initialWorkspace: String, capacity: Int = 1_048_576) throws {
        guard !id.isEmpty, (1...4_194_304).contains(capacity) else { throw HarnessError.invalid("Invalid terminal observation capacity") }
        self.id = id; self.initialWorkspace = initialWorkspace; self.capacity = capacity
        self.latestDirectory = initialWorkspace
    }
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard exit == nil else { lock.unlock(); return }
        end += Int64(data.count)
        if data.count >= capacity { bytes = Data(data.suffix(capacity)) }
        else {
            bytes.append(data)
            if bytes.count > capacity { bytes = Data(bytes.suffix(capacity)) }
        }
        let ready = drainBytesLocked()
        lock.unlock()
        resume(ready)
    }
    public func finish(_ result: PTYExit) {
        lock.lock()
        guard exit == nil else { lock.unlock(); return }
        exit = result
        let ready = drainAllLocked()
        lock.unlock()
        resume(ready)
    }
    /// Records a `preexec` marker. The record stays open (`endedAt == nil`)
    /// until the matching `precmd` arrives. Output bytes never close it. A new
    /// start that arrives while the tail is still open supersedes it: the older
    /// record is closed with no exit code rather than left open to steal a
    /// later `precmd`.
    ///
    /// The opened record is stamped with a pairing token (its own `seq`) so a
    /// later `precmd` can prove it belongs to the start this observation
    /// actually recorded. The token is valid only until it is consumed by a
    /// ready or invalidated by a known marker loss.
    public func recordStart(command: String, directory: String, at date: Date = Date()) {
        lock.lock()
        if let last = commands.last, last.command != nil, last.endedAt == nil {
            commands[commands.count - 1] = TerminalCommand(seq: last.seq, command: last.command,
                                                           directory: last.directory, exitCode: nil,
                                                           startedAt: last.startedAt, endedAt: date)
        }
        commandSeq += 1
        commands.append(TerminalCommand(seq: commandSeq, command: Self.clamp(command, to: Self.maxCommandBytes),
                                         directory: Self.clamp(directory, to: Self.maxDirectoryBytes),
                                         exitCode: nil, startedAt: date, endedAt: nil))
        openPairToken = commandSeq
        if commands.count > Self.maxCommands { commands.removeFirst(commands.count - Self.maxCommands) }
        let ready = updateDirectoryLocked(directory) ? drainCwdLocked(latestDirectory) : []
        lock.unlock()
        resume(ready)
    }
    /// Marks the open start as un-pairable because the framing layer abandoned a
    /// marker. A ready that arrives afterwards cannot be proven to complete the
    /// record left open, so the guard would otherwise stamp a foreign exit code
    /// and cwd onto it. Clearing the token leaves the orphan exactly as it is,
    /// with no exit code and no fabricated end time (the documented open /
    /// ended-unknown convention); the next ready therefore takes the standalone
    /// (initial-prompt) path instead of completing it.
    public func noteMarkerLoss() {
        lock.lock()
        openPairToken = nil
        lock.unlock()
    }
    /// Records a `precmd` marker. Only the tail can be the open start, and only
    /// when its pairing token still matches the last start this observation
    /// recorded; a ready whose start was lost is never attached to an older
    /// record. A standalone ready (the initial prompt, or one that follows a
    /// known marker loss) is stored with `command == nil`.
    public func recordReady(code: Int, directory: String, at date: Date = Date()) {
        lock.lock()
        var completed: TerminalCommand?
        if let token = openPairToken, let last = commands.last, last.seq == token, last.command != nil, last.endedAt == nil {
            let closed = TerminalCommand(seq: last.seq, command: last.command,
                                         directory: Self.clamp(directory, to: Self.maxDirectoryBytes),
                                         exitCode: code, startedAt: last.startedAt, endedAt: date)
            commands[commands.count - 1] = closed
            completed = closed
            openPairToken = nil
            finishedCommands += 1
        } else {
            openPairToken = nil
            commandSeq += 1
            commands.append(TerminalCommand(seq: commandSeq, command: nil,
                                            directory: Self.clamp(directory, to: Self.maxDirectoryBytes),
                                            exitCode: code, startedAt: date, endedAt: date))
            if commands.count > Self.maxCommands { commands.removeFirst(commands.count - Self.maxCommands) }
        }
        var ready: [(Waiter, TerminalRead)] = []
        if let completed { ready += drainFinishedLocked(completed) }
        if updateDirectoryLocked(directory) { ready += drainCwdLocked(latestDirectory) }
        lock.unlock()
        resume(ready)
    }
    private func updateDirectoryLocked(_ directory: String) -> Bool {
        let clamped = Self.clamp(directory, to: Self.maxDirectoryBytes)
        guard !clamped.isEmpty, clamped != latestDirectory else { return false }
        latestDirectory = clamped
        cwdChanges += 1
        return true
    }
    /// Most recent command records, oldest first, bounded by `limit`.
    public func commandHistory(limit: Int = 32) -> [TerminalCommand] {
        lock.lock(); defer { lock.unlock() }
        return Array(commands.suffix(max(1, min(limit, Self.maxCommands))))
    }
    public func commandCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return commands.count
    }
    /// One lock covers the bounded records, the total count and the current
    /// directory so `terminal_commands` never reads a torn snapshot.
    public func commandSnapshot(limit: Int = 32) -> (commands: [TerminalCommand], total: Int, cwd: String) {
        lock.lock(); defer { lock.unlock() }
        return (Array(commands.suffix(max(1, min(limit, Self.maxCommands)))), commands.count, latestDirectory)
    }
    public var currentDirectory: String {
        lock.lock(); defer { lock.unlock() }
        return latestDirectory
    }
    private static func clamp(_ value: String, to byteLimit: Int) -> String {
        guard value.utf8.count > byteLimit else { return value }
        var data = Data(value.utf8.prefix(byteLimit))
        while !data.isEmpty && String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }
    public func inspect() -> TerminalInfo {
        lock.lock(); defer { lock.unlock() }
        let foregroundPgid = foreground?()
        let foregroundBusy: Bool? = (shellPgid > 0 && foregroundPgid != nil) ? foregroundPgid != shellPgid : nil
        return TerminalInfo(id: id, initialWorkspace: initialWorkspace, firstCursor: end - Int64(bytes.count), latestCursor: end,
                            retainedBytes: bytes.count, pendingWaits: waiters.count, exit: exit,
                            foregroundPgid: foregroundPgid,
                            foregroundBusy: foregroundBusy)
    }
    /// Ties this observation to the PTY that owns it. The provider is called
    /// under the observation lock and only takes the PTY's own lock, so the
    /// two locks are never acquired in the opposite order.
    public func attachForeground(shellPgid: Int32, provider: @escaping @Sendable () -> Int32?) {
        lock.lock(); self.shellPgid = shellPgid; self.foreground = provider; lock.unlock()
    }
    public func read(after cursor: Int64, maxBytes: Int = 16384) throws -> TerminalRead {
        lock.lock(); defer { lock.unlock() }
        try validateLocked(cursor, maxBytes)
        return readLocked(cursor, maxBytes)
    }
    /// Completes on the requested condition, a retention gap (which ends a
    /// `bytes` wait only), PTY exit, timeout, or cancellation. An exit result
    /// means the whole PTY exited, not an arbitrary command inside it. The wait
    /// is the wake: there is no hidden idle-agent auto-wake.
    public func wait(after cursor: Int64, maxBytes: Int = 16384, timeout: Double = 30,
                     condition: TerminalWaitCondition = .bytes) async throws -> TerminalRead {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw HarnessError.invalid("Terminal wait timeout must be in (0, 60]") }
        guard condition.isRequestable else { throw HarnessError.invalid("Terminal wait condition must be bytes, command_finished or cwd_changed") }
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                do {
                    try Task.checkCancellation()
                    try validateLocked(cursor, maxBytes)
                    if exit != nil {
                        let result = readLocked(cursor, maxBytes, condition: .exit)
                        lock.unlock(); continuation.resume(returning: result); return
                    }
                    if condition == .bytes, end > cursor {
                        let result = readLocked(cursor, maxBytes, condition: .bytes)
                        lock.unlock(); continuation.resume(returning: result); return
                    }
                    guard waiters.count < 32 else { throw HarnessError.invalid("Too many terminal waiters") }
                    let timer = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                        self?.timeout(token)
                    }
                    let baseline = condition == .commandFinished ? finishedCommands : cwdChanges
                    waiters[token] = Waiter(cursor: cursor, limit: maxBytes, condition: condition, baseline: baseline,
                                            continuation: continuation, timer: timer)
                    lock.unlock()
                } catch { lock.unlock(); continuation.resume(throwing: error) }
            }
        } onCancel: { self.cancel(token) }
    }
    private func validateLocked(_ cursor: Int64, _ limit: Int) throws {
        guard cursor >= 0, cursor <= end, (1...65536).contains(limit) else { throw HarnessError.invalid("Invalid terminal cursor or read limit") }
    }
    private func readLocked(_ cursor: Int64, _ limit: Int, timedOut: Bool = false, condition: TerminalWaitCondition? = nil,
                            command: TerminalCommand? = nil, cwd: String? = nil) -> TerminalRead {
        let first = end - Int64(bytes.count)
        let start = max(cursor, first)
        let count = min(limit, Int(end - start))
        let offset = Int(start - first)
        let chunk = Data(bytes.dropFirst(offset).prefix(count))
        return TerminalRead(terminalID: id, startCursor: start, nextCursor: start + Int64(count), latestCursor: end,
                            gap: cursor < first, bytes: chunk, text: String(decoding: chunk, as: UTF8.self), exit: exit,
                            timedOut: timedOut, condition: condition, command: command, cwd: cwd)
    }
    private func drainBytesLocked() -> [(Waiter, TerminalRead)] {
        var entries: [(Waiter, TerminalRead)] = []
        for (token, waiter) in Array(waiters) where waiter.condition == .bytes && end > waiter.cursor {
            waiters.removeValue(forKey: token)
            entries.append((waiter, readLocked(waiter.cursor, waiter.limit, condition: .bytes)))
        }
        return entries
    }
    private func drainAllLocked() -> [(Waiter, TerminalRead)] {
        var entries: [(Waiter, TerminalRead)] = []
        for (token, waiter) in Array(waiters) {
            waiters.removeValue(forKey: token)
            entries.append((waiter, readLocked(waiter.cursor, waiter.limit, condition: .exit)))
        }
        return entries
    }
    private func drainFinishedLocked(_ command: TerminalCommand) -> [(Waiter, TerminalRead)] {
        var entries: [(Waiter, TerminalRead)] = []
        for (token, waiter) in Array(waiters) where waiter.condition == .commandFinished && waiter.baseline < finishedCommands {
            waiters.removeValue(forKey: token)
            entries.append((waiter, readLocked(waiter.cursor, waiter.limit, condition: .commandFinished,
                                               command: command, cwd: command.directory)))
        }
        return entries
    }
    private func drainCwdLocked(_ directory: String) -> [(Waiter, TerminalRead)] {
        var entries: [(Waiter, TerminalRead)] = []
        for (token, waiter) in Array(waiters) where waiter.condition == .cwdChanged && waiter.baseline < cwdChanges {
            waiters.removeValue(forKey: token)
            entries.append((waiter, readLocked(waiter.cursor, waiter.limit, condition: .cwdChanged, cwd: directory)))
        }
        return entries
    }
    private func resume(_ entries: [(Waiter, TerminalRead)]) {
        for (waiter, result) in entries { waiter.timer.cancel(); waiter.continuation.resume(returning: result) }
    }
    private func timeout(_ token: UUID) {
        lock.lock()
        guard let waiter = waiters.removeValue(forKey: token) else { lock.unlock(); return }
        let result = readLocked(waiter.cursor, waiter.limit, timedOut: true, condition: .timeout)
        lock.unlock(); waiter.continuation.resume(returning: result)
    }
    private func cancel(_ token: UUID) {
        lock.lock(); let waiter = waiters.removeValue(forKey: token); lock.unlock()
        waiter?.timer.cancel(); waiter?.continuation.resume(throwing: CancellationError())
    }
}

/// A bounded observation catalog. It intentionally exposes no keyboard control.
public final class TerminalObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [TerminalObservation] = []
    public init() {}
    public func create(id: String, workspace: String) throws -> TerminalObservation {
        lock.lock(); defer { lock.unlock() }
        guard !entries.contains(where: { $0.id == id }) else { throw HarnessError.invalid("Duplicate terminal ID") }
        if entries.count >= 8 {
            guard let index = entries.firstIndex(where: { $0.inspect().exit != nil }) else { throw HarnessError.invalid("Terminal observation limit reached") }
            entries.remove(at: index)
        }
        let entry = try TerminalObservation(id: id, initialWorkspace: workspace)
        entries.append(entry); return entry
    }
    public func discard(id: String) { lock.lock(); entries.removeAll { $0.id == id }; lock.unlock() }
    public func list() -> [TerminalInfo] { lock.lock(); defer { lock.unlock() }; return entries.map { $0.inspect() } }
    public func find(_ id: String) throws -> TerminalObservation {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries.first(where: { $0.id == id }) else { throw HarnessError.invalid("Unknown or evicted terminal ID") }
        return entry
    }
}
