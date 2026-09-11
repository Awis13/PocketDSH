import Foundation

// The Host's /command catalog wire contract, ported 1:1 from the shipped
// @deepseek-ai/dsh-commands and @deepseek-ai/dsh-client-ui-commands
// packages. Self-contained value types plus one cache class: no PocketStore,
// no SwiftUI/UIKit, no concurrency annotations, so the offline checks can
// compile this file on its own.
//
// Wire shapes mirror the shipped Host packages; the names below cite the
// declaration each model reads, so a later change has one place to look.

// MARK: - Value models

/// `CommandInputDescriptor` - dsh-commands: the command's input-line
/// descriptor. `attachments` is absent when the command takes none.
struct CommandInputDescriptor: Equatable {
    var hint = ""
    var attachments: Bool?
    init(_ value: JSON = .null) {
        guard !value.object.isEmpty else { return }
        hint = value["hint"].string
        if case .bool(let on) = value["attachments"] { attachments = on }
    }
}

/// `CommandDescriptor` - dsh-commands: one command in the per-session catalog.
struct CommandDescriptor: Equatable {
    var name = ""
    var description = ""
    var input: CommandInputDescriptor?
    init(_ value: JSON = .null) {
        guard !value.object.isEmpty else { return }
        name = value["name"].string
        description = value["description"].string
        let input = value["input"]
        self.input = input == .null ? nil : CommandInputDescriptor(input)
    }
}

/// `CommandResult` - dsh-commands: the execution outcome of one command.
/// `text` is optional in both kinds; `sourceEventSeq` (success only) points
/// at the authoritative domain event - presentation-only, the execute-RPC
/// consumer never reads it.
struct CommandResult: Equatable {
    var kind = ""
    var text: String?
    var sourceEventSeq: Int?
    var isSuccess: Bool { kind == "success" }
    var isError: Bool { kind == "error" }
    init(_ value: JSON = .null) {
        kind = value["kind"].string
        if case .string(let text) = value["text"] { self.text = text }
        if case .number = value["sourceEventSeq"] { sourceEventSeq = value["sourceEventSeq"].int }
    }
}

/// `CommandExecution` - dsh-commands: the execute-RPC result, pairing one
/// commandId with its outcome.
struct CommandExecution: Equatable {
    var commandId = ""
    var result = CommandResult(.null)
    init(_ value: JSON = .null) {
        guard !value.object.isEmpty else { return }
        commandId = value["commandId"].string
        result = CommandResult(value["result"])
    }
}

/// `CommandSubmitAttachment` - dsh-commands: what rides with a submitted
/// command line. An image is inline base64 (`type: "image"`, the
/// dsh-attachment EncodedImageAttachment); a file references a receipt the
/// Host admitted earlier.
struct CommandSubmitAttachment: Equatable {
    var type = ""
    var mediaType = ""
    var data = ""
    var name: String?
    var receiptId: String?
    var isFile: Bool { type == "file" }
    init(_ value: JSON = .null) {
        guard !value.object.isEmpty else { return }
        type = value["type"].string
        mediaType = value["mediaType"].string
        data = value["data"].string
        if case .string(let name) = value["name"] { self.name = name }
        if case .string(let receiptId) = value["receiptId"] { self.receiptId = receiptId }
    }
}

/// `command/run` - dsh-commands session event: the Host started executing a
/// command (session/follow stream, paired with `command/done` by commandId).
/// `args` is absent when the definition sets `recordInput: false`.
struct CommandRunEvent: Equatable {
    var commandId = ""
    var name = ""
    var args: String?
    var sourceKind = ""
    init(_ value: JSON = .null) {
        guard !value.object.isEmpty else { return }
        commandId = value["commandId"].string
        name = value["name"].string
        if case .string(let args) = value["args"] { self.args = args }
        sourceKind = value["source"]["kind"].string
    }
}

/// `command/done` - dsh-commands session event: the paired command settled.
/// `kind`/`text` carry the handler's verbatim outcome (a thrown or aborted
/// handler settles as kind "error" with the rendered failure).
struct CommandDoneEvent: Equatable {
    var commandId = ""
    var kind = ""
    var text: String?
    var sourceEventSeq: Int?
    init(_ value: JSON = .null) {
        guard !value.object.isEmpty else { return }
        commandId = value["commandId"].string
        kind = value["kind"].string
        if case .string(let text) = value["text"] { self.text = text }
        if case .number = value["sourceEventSeq"] { sourceEventSeq = value["sourceEventSeq"].int }
    }
}

/// Decode a `commands/list` payload: the catalog array, or [] on a non-array.
func commandDescriptors(_ value: JSON) -> [CommandDescriptor] {
    value.array.map { CommandDescriptor($0) }
}

// MARK: - Line parsing

/// `dsh-commands` parseCommand, ported 1:1. The JS original (lib/index.js)
/// is /^\/([a-z][a-z0-9_-]*)(?=$|[\t\n\r ])/u - the character sets are
/// ASCII, like the JS [a-z] and [a-z0-9_-] classes.
///
/// Host-faithful: NO trim inside. The JS caller trims before calling (the
/// web client does), so an untrimmed line misses, exactly as in the Host.
/// The lookahead is zero-width, so the separator stays OUT of the match and
/// rawInput KEEPS it: "/compact now" -> ("compact", " now").
func parseCommand(_ line: String) -> (name: String, rawInput: String)? {
    let scalars = Array(line.unicodeScalars)
    guard scalars.count >= 2, scalars[0].value == 47, isCommandStart(scalars[1].value) else { return nil }
    var end = 2
    while end < scalars.count, isCommandPart(scalars[end].value) { end += 1 }
    guard end == scalars.count || isCommandSeparator(scalars[end].value) else { return nil }
    return (decode(scalars[1..<end]), decode(scalars[end...]))
}

private func isCommandStart(_ scalar: UInt32) -> Bool { (97...122).contains(scalar) }
private func isCommandPart(_ scalar: UInt32) -> Bool {
    (48...57).contains(scalar) || (97...122).contains(scalar) || scalar == 45 || scalar == 95
}
/// The JS separator class [\t\n\r ]: tab, LF, CR and space - nothing else.
private func isCommandSeparator(_ scalar: UInt32) -> Bool {
    scalar == 9 || scalar == 10 || scalar == 13 || scalar == 32
}

/// `dsh-client-ui-commands` client.js submittedCommandName: trim, take the
/// first whitespace-delimited token, strip the leading "/".
///
/// The JS original drops the token's first character unconditionally
/// (.slice(1)) because its input is a line the Host confirmed as executed -
/// by contract the token starts with "/". This port strips the slash only
/// when present, so an out-of-contract slash-less line degrades to the token
/// itself instead of the token minus its first character.
func submittedCommandName(_ line: String) -> String {
    let scalars = Array(line.unicodeScalars)
    guard !scalars.isEmpty else { return "" }
    var lo = 0
    var hi = scalars.count - 1
    while lo <= hi, isCommandLineWhitespace(scalars[lo].value) { lo += 1 }
    while hi >= lo, isCommandLineWhitespace(scalars[hi].value) { hi -= 1 }
    guard lo <= hi else { return "" }
    var end = lo
    while end <= hi, !isCommandLineWhitespace(scalars[end].value) { end += 1 }
    let token = scalars[lo..<end]
    guard token.first?.value == 47 else { return decode(token) }
    return decode(token.dropFirst())
}

private func decode(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
    String(decoding: scalars.map { $0.value }, as: UTF32.self)
}

/// JS trim()/\s whitespace, ASCII plus NBSP.
private func isCommandLineWhitespace(_ scalar: UInt32) -> Bool {
    (9...13).contains(scalar) || scalar == 32 || scalar == 160
}

// MARK: - Directory cache

/// The session-keyed command catalog cache - a full port of
/// dsh-client-ui-commands' CommandDirectory (lib/client.js).
///
/// Threading: the JS original runs on a single UI thread; this port keeps
/// that assumption. The fetch closure runs synchronously inside refresh, so
/// a pull is "in flight" only while that closure executes; tests drive the
/// class with deterministic closures and no concurrency.
///
/// Epoch guard: every refresh bumps the entry's epoch; only the latest epoch
/// may publish its outcome, in the success arm and in the failure arm. A
/// ready snapshot is never demoted while a pull flies - except when that
/// pull's own outcome is a failure, which publishes failed (the reference
/// semantics, kept exactly).
final class CommandDirectory {
    /// The entry states: cold (untouched), pending (a pull is in flight),
    /// ready (a snapshot serves), failed (the last winning publish failed).
    enum State: String { case cold, pending, ready, failed }

    /// One session key's cache cell - the JS Entry, field for field.
    struct Entry {
        var state: State = .cold
        var commands: [CommandDescriptor] = []
        /// Bumped at each pull start; only the latest pull may publish.
        var epoch = 0
        var lastError: Error?
        /// JS settled() waiters: once-resolve closures woken by the drain.
        var waiters: [() -> Void] = []
    }

    /// ensureReady's failure; mirrors the JS `command directory warmup failed: ...` throw.
    struct WarmupFailure: Error, Equatable {
        var reason = ""
    }

    private(set) var entries: [String: Entry] = [:]
    private let fetchCommands: (String) throws -> [CommandDescriptor]

    init(fetchCommands: @escaping (String) throws -> [CommandDescriptor]) {
        self.fetchCommands = fetchCommands
    }

    /// Current cache status for one session; "cold" when never touched.
    func status(_ sessionId: String) -> State {
        entries[sessionId]?.state ?? .cold
    }

    /// Synchronous exact-name lookup over one session's hot snapshot;
    /// nil when absent or the entry is not ready.
    func resolve(_ sessionId: String, _ name: String) -> CommandDescriptor? {
        guard let entry = entries[sessionId], entry.state == .ready else { return nil }
        return entry.commands.first { $0.name == name }
    }

    /// Soft invalidation (commands/change): a background repull on every
    /// touched key; ready snapshots keep serving while the pulls fly.
    func invalidateAll() {
        for key in entries.keys { refresh(key) }
    }

    /// Drop one session's obsolete snapshot (agent-preset/selected) and
    /// prewarm its replacement.
    func resetSession(_ sessionId: String) {
        var entry = entries[sessionId] ?? Entry()
        entry.state = .cold
        entry.commands = []
        entry.lastError = nil
        entries[sessionId] = entry
        refresh(sessionId)
    }

    /// Hard reset on reconnect (connection/reset): every entry drops its
    /// snapshot and prewarms.
    func resetConnected() {
        for key in Array(entries.keys) {
            var entry = entries[key]!
            entry.state = .cold
            entry.commands = []
            entries[key] = entry
            refresh(key)
        }
    }

    /// Fire-and-forget prewarm: only cold or failed entries pull.
    func warm(_ sessionId: String) {
        let entry = entries[sessionId] ?? Entry()
        entries[sessionId] = entry
        if entry.state == .cold || entry.state == .failed { refresh(sessionId) }
    }

    /// Start one pull for one session. Publishes ready/failed only while it
    /// is still the key's latest pull (epoch guard); a ready snapshot is not
    /// demoted while the pull flies. Returns the pull's epoch.
    @discardableResult
    func refresh(_ sessionId: String) -> Int {
        var entry = entries[sessionId] ?? Entry()
        entry.epoch += 1
        let epoch = entry.epoch
        if entry.state != .ready { entry.state = .pending }
        entries[sessionId] = entry
        var outcome: Result<[CommandDescriptor], Error>?
        do { outcome = .success(try fetchCommands(sessionId)) }
        catch { outcome = .failure(error) }
        if var current = entries[sessionId] {
            switch outcome! {
            case .success(let commands):
                if epoch == current.epoch {
                    current.commands = commands
                    current.state = .ready
                    current.lastError = nil
                    entries[sessionId] = current
                }
            case .failure(let error):
                if epoch == current.epoch {
                    current.commands = []
                    current.state = .failed
                    current.lastError = error
                    entries[sessionId] = current
                }
            }
        }
        // finally: wake waiters only on a winning publish.
        if entries[sessionId]?.epoch == epoch { notifyWaiters(sessionId) }
        return epoch
    }

    /// JS settled(entry): register a once-resolve waiter woken by the next
    /// winning publish. The JS abort-signal handling belongs to the C2
    /// caller; the synchronous port has no signal.
    func settle(_ sessionId: String, _ waiter: @escaping () -> Void) {
        var entry = entries[sessionId] ?? Entry()
        entry.waiters.append(waiter)
        entries[sessionId] = entry
    }

    /// JS ensureReady: strong-wait until the catalog is servable - ready
    /// returns at once, cold/failed launch a fresh pull, pending joins the
    /// flying one. Synchronous port: a pull started inside this call has
    /// published before it returns, so the waiter loop collapses to a state
    /// re-check; a pending state (observable only re-entrantly from inside a
    /// fetch closure) throws where the JS original would suspend on the
    /// waiter.
    func ensureReady(_ sessionId: String) throws -> [CommandDescriptor] {
        while true {
            switch status(sessionId) {
            case .ready:
                return entries[sessionId]?.commands ?? []
            case .pending:
                throw WarmupFailure(reason: "command directory warmup failed: pull in flight")
            case .cold, .failed:
                refresh(sessionId)
            }
            if status(sessionId) == .failed, let entry = entries[sessionId] {
                throw WarmupFailure(reason: "command directory warmup failed: " + commandErrorMessage(entry.lastError))
            }
        }
    }

    private func notifyWaiters(_ sessionId: String) {
        guard var entry = entries[sessionId] else { return }
        let woken = entry.waiters
        entry.waiters = []
        entries[sessionId] = entry
        for wake in woken { wake() }
    }
}

/// The JS throw renders lastError.message (or String(lastError) for a
/// non-Error throw value); the Swift port reads the LocalizedError
/// description and falls back to the default description.
func commandErrorMessage(_ error: Error?) -> String {
    guard let error else { return "unknown error" }
    if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
    return "\(error)"
}
