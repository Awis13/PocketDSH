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

public struct TerminalInfo: Codable, Sendable {
    public let id: String
    public let initialWorkspace: String
    public let firstCursor: Int64
    public let latestCursor: Int64
    public let retainedBytes: Int
    public let pendingWaits: Int
    public let exit: PTYExit?
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
    private var latestDirectory: String
    private struct Waiter {
        let cursor: Int64
        let limit: Int
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
        let ready = drainLocked()
        lock.unlock()
        resume(ready)
    }
    public func finish(_ result: PTYExit) {
        lock.lock()
        guard exit == nil else { lock.unlock(); return }
        exit = result
        let ready = drainLocked()
        lock.unlock()
        resume(ready)
    }
    /// Records a `preexec` marker. The record stays open (`endedAt == nil`)
    /// until the matching `precmd` arrives. Output bytes never close it.
    public func recordStart(command: String, directory: String, at date: Date = Date()) {
        lock.lock()
        commandSeq += 1
        commands.append(TerminalCommand(seq: commandSeq, command: Self.clamp(command, to: Self.maxCommandBytes),
                                         directory: Self.clamp(directory, to: Self.maxDirectoryBytes),
                                         exitCode: nil, startedAt: date, endedAt: nil))
        if commands.count > Self.maxCommands { commands.removeFirst(commands.count - Self.maxCommands) }
        latestDirectory = Self.clamp(directory, to: Self.maxDirectoryBytes)
        lock.unlock()
    }
    /// Records a `precmd` marker. A standalone ready (the initial prompt) is
    /// stored with `command == nil`; later ready frames close the open start.
    public func recordReady(code: Int, directory: String, at date: Date = Date()) {
        lock.lock()
        if let index = commands.lastIndex(where: { $0.command != nil && $0.endedAt == nil }) {
            let open = commands[index]
            commands[index] = TerminalCommand(seq: open.seq, command: open.command,
                                              directory: Self.clamp(directory, to: Self.maxDirectoryBytes),
                                              exitCode: code, startedAt: open.startedAt, endedAt: date)
        } else {
            commandSeq += 1
            commands.append(TerminalCommand(seq: commandSeq, command: nil,
                                            directory: Self.clamp(directory, to: Self.maxDirectoryBytes),
                                            exitCode: code, startedAt: date, endedAt: date))
            if commands.count > Self.maxCommands { commands.removeFirst(commands.count - Self.maxCommands) }
        }
        latestDirectory = Self.clamp(directory, to: Self.maxDirectoryBytes)
        lock.unlock()
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
        return TerminalInfo(id: id, initialWorkspace: initialWorkspace, firstCursor: end - Int64(bytes.count), latestCursor: end,
                            retainedBytes: bytes.count, pendingWaits: waiters.count, exit: exit)
    }
    public func read(after cursor: Int64, maxBytes: Int = 16384) throws -> TerminalRead {
        lock.lock(); defer { lock.unlock() }
        try validateLocked(cursor, maxBytes)
        return readLocked(cursor, maxBytes)
    }
    /// Completes on new bytes, retention gap, PTY exit, timeout, or cancellation.
    /// An exit result means the whole PTY exited, not an arbitrary command inside it.
    public func wait(after cursor: Int64, maxBytes: Int = 16384, timeout: Double = 30) async throws -> TerminalRead {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw HarnessError.invalid("Terminal wait timeout must be in (0, 60]") }
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                do {
                    try Task.checkCancellation()
                    try validateLocked(cursor, maxBytes)
                    if end > cursor || exit != nil {
                        let result = readLocked(cursor, maxBytes)
                        lock.unlock(); continuation.resume(returning: result); return
                    }
                    guard waiters.count < 32 else { throw HarnessError.invalid("Too many terminal waiters") }
                    let timer = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                        self?.timeout(token)
                    }
                    waiters[token] = Waiter(cursor: cursor, limit: maxBytes, continuation: continuation, timer: timer)
                    lock.unlock()
                } catch { lock.unlock(); continuation.resume(throwing: error) }
            }
        } onCancel: { self.cancel(token) }
    }
    private func validateLocked(_ cursor: Int64, _ limit: Int) throws {
        guard cursor >= 0, cursor <= end, (1...65536).contains(limit) else { throw HarnessError.invalid("Invalid terminal cursor or read limit") }
    }
    private func readLocked(_ cursor: Int64, _ limit: Int, timedOut: Bool = false) -> TerminalRead {
        let first = end - Int64(bytes.count)
        let start = max(cursor, first)
        let count = min(limit, Int(end - start))
        let offset = Int(start - first)
        let chunk = Data(bytes.dropFirst(offset).prefix(count))
        return TerminalRead(terminalID: id, startCursor: start, nextCursor: start + Int64(count), latestCursor: end,
                            gap: cursor < first, bytes: chunk, text: String(decoding: chunk, as: UTF8.self), exit: exit, timedOut: timedOut)
    }
    private func drainLocked() -> [(Waiter, TerminalRead)] {
        let entries = Array(waiters.values); waiters.removeAll()
        return entries.map { ($0, readLocked($0.cursor, $0.limit)) }
    }
    private func resume(_ entries: [(Waiter, TerminalRead)]) {
        for (waiter, result) in entries { waiter.timer.cancel(); waiter.continuation.resume(returning: result) }
    }
    private func timeout(_ token: UUID) {
        lock.lock()
        guard let waiter = waiters.removeValue(forKey: token) else { lock.unlock(); return }
        let result = readLocked(waiter.cursor, waiter.limit, timedOut: true)
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
