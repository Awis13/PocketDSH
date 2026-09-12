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

// MARK: - RPC wire arguments

extension CommandSubmitAttachment {
    /// The exact wire object for one submission attachment, or nil when the
    /// value has no valid union arm at all. An image is the dsh-attachment
    /// EncodedImageAttachment fields under `type: "image"`; a file is the
    /// staged receipt reference. The union declares neither an empty receipt
    /// nor a null form, so a caller that gets nil refuses the submission
    /// instead of sending an empty receipt the Host would reject.
    var wire: JSON? {
        var fields: [String: JSON] = ["type": .string(type)]
        if isFile {
            guard let receiptId, !receiptId.isEmpty else { return nil }
            fields["receiptId"] = .string(receiptId)
        } else {
            guard !mediaType.isEmpty, !data.isEmpty else { return nil }
            fields["mediaType"] = .string(mediaType)
            fields["data"] = .string(data)
            if let name { fields["name"] = .string(name) }
        }
        return .object(fields)
    }
}

/// The `commands/list` wire arguments: `list: (agentId: SessionId)`
/// (dsh-commands/lib/typert.remote-client.d.ts). Sessions are always
/// agent-backed, so the session id IS the agent id the Host expects.
func commandListArguments(agentId: String) -> [String: JSON] {
    ["agentId": .string(agentId)]
}

/// The `commands/execute` wire arguments:
/// `execute: (agentId, line, submittedAttachments)`
/// (dsh-commands/lib/typert.remote-client.d.ts). The third parameter is
/// `submittedAttachments`; the Host declares no `images` parameter, so an
/// invocation carrying attachments under any other name is rejected.
func commandExecuteArguments(agentId: String, line: String, submittedAttachments: [JSON]) -> [String: JSON] {
    ["agentId": .string(agentId), "line": .string(line), "submittedAttachments": .array(submittedAttachments)]
}

/// Whether one command admits an invocation that carries attachments. The
/// reference refuses the submission otherwise (dsh-client-ui-commands
/// client.js matchEnter: `desc.input.attachments !== true`), so the caller
/// keeps the draft and the attachments instead of dropping them.
func commandAdmitsAttachments(_ descriptor: CommandDescriptor) -> Bool {
    descriptor.input?.attachments == true
}

/// Where one session's command catalog comes from.
enum CommandCatalogRequest: Equatable {
    /// The `commands/list` RPC, addressed to the session's own agent.
    case list(agentId: String)
    /// A subagent session: no RPC, and the catalog is empty.
    case emptyCatalog
}

/// Decide one catalog pull. The reference client short-circuits a subagent
/// session to an empty list before the RPC (dsh-client-ui-commands
/// client.js:519-524): the subagent has no interactive command surface of its
/// own, and the Host would answer for the parent's composition.
func commandCatalogRequest(sessionId: String, origin: String) -> CommandCatalogRequest {
    origin == "subagent" ? .emptyCatalog : .list(agentId: sessionId)
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

/// One pull's outcome as a caller reports it back to the directory.
typealias CommandFetchOutcome = Result<[CommandDescriptor], Error>

/// The session-keyed command catalog cache - a full port of
/// dsh-client-ui-commands' CommandDirectory (lib/client.js).
///
/// Isolation: the JS original runs on one UI thread and the app keeps that
/// shape - PocketStore is `@MainActor`, a pull is handed back with
/// `Task { @MainActor in ... }` and `ensureReadyAsync` is awaited from main-
/// actor code - so the class is `@MainActor` and every cache mutation is
/// serialized by construction. The offline checks drive it on the main actor
/// too, which is what makes the wait/join interleavings deterministic: an
/// off-actor read of `entries` racing a publish is a data race, not a test
/// nuance.
///
/// Pull identity: an outcome lands only while the full identity it was
/// minted under is still the key's current one. The identity is a
/// `CommandPullToken` - the session key, the entry's epoch, and the
/// catalog generation. The epoch orders the pulls of one connection
/// (a ready snapshot is never demoted while a pull flies - except when that
/// pull's own outcome is a failure, which publishes failed, the reference
/// semantics kept exactly); the generation orders the connections, because
/// it is bumped by `removeAll` and the epoch alone restarts at 1 after a
/// clear, so a late outcome of a dead connection would otherwise collide
/// with a fresh pull of the next one. Success, failure and abandon are
/// shielded identically.
@MainActor
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
        /// `true` is a clear (cancellation), `false` a winning publish.
        var waiters: [(Bool) -> Void] = []
    }

    /// One pull's identity, minted by `beginPull` and required back by
    /// `publish` and `abandon`. `catalogGeneration` is the directory's
    /// generation at mint time, so a token outlives its connection: after
    /// `removeAll` both the generation moved on and the entry is gone, and
    /// neither a fresh pull nor a fresh connection can be addressed with it.
    /// Hashable so a caller can key its in-flight pulls by identity (the
    /// store's connection-scoped cancellation does).
    struct CommandPullToken: Equatable, Hashable {
        let sessionId: String
        let epoch: Int
        let catalogGeneration: Int
    }

    /// ensureReady's failure; mirrors the JS `command directory warmup failed: ...` throw.
    struct WarmupFailure: Error, Equatable {
        var reason = ""
    }

    /// The distinct outcome of a wait whose catalog was cleared under it
    /// (a connection tearing down). It is not a pull failure: nothing was
    /// attempted and nothing may be retried, so `ensureReadyAsync` reports
    /// it instead of repulling, and the app treats it as a quiet no-op.
    struct CommandPullCancelled: Error, Equatable {
        var reason = "the command catalog was dropped with its connection"
    }

    private(set) var entries: [String: Entry] = [:]
    /// Bumped whenever `removeAll` clears the map. Every token minted before
    /// the bump carries the old value and can never address an entry again.
    private(set) var catalogGeneration = 0
    /// The synchronous pull the offline checks drive.
    private let fetchCommands: ((String) throws -> [CommandDescriptor])?
    /// The asynchronous pull the app hands to its RPC. The JS fetch is a
    /// promise, which a Swift closure cannot be, so the pull is split: the
    /// directory mints the token and hands it to the caller, and the caller
    /// publishes the outcome back under it.
    private let startPull: ((CommandPullToken) -> Void)?

    init(fetchCommands: @escaping (String) throws -> [CommandDescriptor]) {
        self.fetchCommands = fetchCommands
        self.startPull = nil
    }

    /// The async-caller seam: every pull this directory starts (warm,
    /// invalidateAll, resetSession, resetConnected, ensureReady, refresh) goes
    /// to `startPull`, whose outcome must be published with `publish`.
    init(startPull: @escaping (CommandPullToken) -> Void) {
        self.fetchCommands = nil
        self.startPull = startPull
    }

    /// Current cache status for one session; "cold" when never touched.
    func status(_ sessionId: String) -> State {
        entries[sessionId]?.state ?? .cold
    }

    /// The hot snapshot one session serves, or [] when the entry is not ready.
    func snapshot(_ sessionId: String) -> [CommandDescriptor] {
        guard let entry = entries[sessionId], entry.state == .ready else { return [] }
        return entry.commands
    }

    /// Drop every cached entry and open a new catalog generation. The
    /// reference directory lives as long as the plugin; this client drops it
    /// when a connection tears down, so a stale snapshot can never answer for
    /// the next connection - and the generation bump is what keeps a late
    /// outcome of the dead connection (a success, a failure, or an abandon)
    /// from landing on the cleared map, where the next connection's pull
    /// restarts at epoch 1 with the same session key.
    ///
    /// Waiters parked on the cleared entries end here, deterministically, with
    /// `CommandPullCancelled`: they must neither re-home onto the next
    /// connection nor be rejected by the dead connection's outcome, so the
    /// wait is cancelled instead of being woken into another pull. The new
    /// generation is installed before the waiters run, so a waiter that
    /// registers a fresh pull during the drain does so against the new one.
    func removeAll() {
        let woken = entries.values.flatMap(\.waiters)
        entries.removeAll()
        catalogGeneration += 1
        for wake in woken { wake(true) }
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

    /// Start one pull for one session. Publishes ready/failed only while its
    /// token is still the key's current identity; a ready snapshot is not
    /// demoted while the pull flies. Returns the pull's token.
    @discardableResult
    func refresh(_ sessionId: String) -> CommandPullToken {
        let token = beginPull(sessionId)
        if let startPull {
            startPull(token)
            return token
        }
        var outcome: CommandFetchOutcome
        do { outcome = .success(try fetchCommands!(sessionId)) }
        catch { outcome = .failure(error) }
        publish(token, outcome)
        return token
    }

    /// Open one pull: bump the key's epoch and mark it pending, under the
    /// directory's current generation. A caller whose fetch is asynchronous
    /// publishes its outcome with `publish` under the returned token; the
    /// synchronous `refresh` is this plus the fetch.
    @discardableResult
    func beginPull(_ sessionId: String) -> CommandPullToken {
        var entry = entries[sessionId] ?? Entry()
        entry.epoch += 1
        if entry.state != .ready { entry.state = .pending }
        entries[sessionId] = entry
        return CommandPullToken(sessionId: sessionId, epoch: entry.epoch, catalogGeneration: catalogGeneration)
    }

    /// Publish one pull's outcome. Ignored unless the token is still the key's
    /// current identity - both the generation and the epoch (the identity
    /// guard) - so a stale outcome never lands, on a newer pull of this
    /// connection or on a later one after a clear, and the winning publish is
    /// what wakes the waiters.
    func publish(_ token: CommandPullToken, _ outcome: CommandFetchOutcome) {
        guard isCurrent(token), let current = entries[token.sessionId] else { return }
        var entry = current
        switch outcome {
        case .success(let commands):
            entry.commands = commands
            entry.state = .ready
            entry.lastError = nil
        case .failure(let error):
            entry.commands = []
            entry.state = .failed
            entry.lastError = error
        }
        entries[token.sessionId] = entry
        notifyWaiters(token.sessionId)
    }

    /// Publish a pull that can no longer report its real outcome because the
    /// connection it belonged to is gone. Dropping such an outcome silently
    /// would leave the key pending forever and strand a strong-wait, so the
    /// pull abandons its token instead; the identity guard keeps an abandoned
    /// pull from touching a newer entry, exactly like a late publish.
    func abandon(_ token: CommandPullToken, reason: Error) {
        publish(token, .failure(reason))
    }

    /// The token that addresses one session's current identity right now:
    /// its live epoch under the current catalog generation. Nil when the
    /// session has no entry (nothing was ever pulled for it), because there
    /// is then no epoch to name. A caller that has to bind an operation to
    /// the connection outside a pull (the store's command path does) mints
    /// its token here and re-checks it with `isCurrent` after every
    /// suspension: if the generation moved, the token is stale.
    func currentToken(_ sessionId: String) -> CommandPullToken? {
        guard let entry = entries[sessionId] else { return nil }
        return CommandPullToken(sessionId: sessionId, epoch: entry.epoch, catalogGeneration: catalogGeneration)
    }

    /// Whether one token still addresses the key's current identity: the
    /// same generation and the same epoch. The generation check is what a
    /// bare epoch cannot express after a clear, when the epoch restarts.
    /// This is also the connection test the store's pull table uses: a token
    /// minted under an older generation is work of a dead connection.
    func isCurrent(_ token: CommandPullToken) -> Bool {
        guard token.catalogGeneration == catalogGeneration, let entry = entries[token.sessionId] else { return false }
        return entry.epoch == token.epoch
    }

    /// JS settled(entry): register a once-resolve waiter woken by the next
    /// winning publish. `ensureReadyAsync` drives this from the app; the JS
    /// abort-signal handling has no counterpart here, so `removeAll` cancelling
    /// the waiters is what keeps a wait from outliving its connection.
    func settle(_ sessionId: String, _ waiter: @escaping (_ cancelled: Bool) -> Void) {
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

    /// JS ensureReady (client.js:118-126) as the asynchronous form the app
    /// uses: strong-wait until one session's catalog is servable - ready
    /// returns at once, cold/failed launch a fresh pull, pending joins the
    /// pull in flight. A failed pull rejects the wait (the reference's "never a
    /// silent downgrade") and repulls on the next wait instead of poisoning the
    /// key. A tear-down cancels the wait with `CommandPullCancelled`: the wait
    /// neither continues on the next connection nor is rejected by the dead
    /// connection's outcome.
    ///
    /// The wait is bound to the catalog generation it started in, and every
    /// suspension re-checks that binding. The generation can move while this
    /// task is runnable but not yet running - `removeAll` may clear the map in
    /// the same main-actor pass that published the outcome this wait was
    /// waiting for - so a wait that outlived its generation must end
    /// cancelled. Without the re-check the loop would read the next
    /// connection's `.ready` entry and serve its snapshot as if it were the
    /// answer to the old operation.
    func ensureReadyAsync(_ sessionId: String) async throws -> [CommandDescriptor] {
        let generation = catalogGeneration
        while true {
            if catalogGeneration != generation { throw CommandPullCancelled() }
            switch status(sessionId) {
            case .ready:
                if catalogGeneration != generation { throw CommandPullCancelled() }
                return entries[sessionId]?.commands ?? []
            case .pending:
                break
            case .cold, .failed:
                refresh(sessionId)
            }
            if let cancellation = await waitForPublish(sessionId) { throw cancellation }
            if catalogGeneration != generation { throw CommandPullCancelled() }
            if status(sessionId) == .failed, let entry = entries[sessionId] {
                throw WarmupFailure(reason: "command directory warmup failed: " + commandErrorMessage(entry.lastError))
            }
        }
    }

    /// One settlement tick: suspend until the key's next winning publish, or
    /// until the catalog generation is cleared under the wait. A publish that
    /// already landed never registers a waiter, so a synchronous pull cannot
    /// deadlock the wait; a tear-down ends the wait instead of stranding it.
    /// Non-nil is the cancellation the wait must report, never re-enter.
    private func waitForPublish(_ sessionId: String) async -> CommandPullCancelled? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CommandPullCancelled?, Never>) in
            let gate = OnceGate(continuation)
            if status(sessionId) == .pending { settle(sessionId) { cancelled in cancelled ? gate.cancel() : gate.resume() } }
            else { gate.resume() }
        }
    }

    /// Resume-once guard: a waiter may be woken by a publish and by a tear-down
    /// in the same tick, and a checked continuation must resume exactly once.
    /// The continuation carries the cancellation when the wake was a clear.
    private final class OnceGate {
        private var continuation: CheckedContinuation<CommandPullCancelled?, Never>?
        init(_ continuation: CheckedContinuation<CommandPullCancelled?, Never>) { self.continuation = continuation }
        /// A winning publish: the wait's continuation with no cancellation.
        func resume() { let pending = continuation; continuation = nil; pending?.resume(returning: nil) }
        /// A clear: the wait ends with the catalog's cancellation.
        func cancel() { let pending = continuation; continuation = nil; pending?.resume(returning: CommandPullCancelled()) }
    }

    /// A winning publish: wake the waiters it was registered for with "not
    /// cancelled". A dropped publish (a stale token) wakes nobody.
    private func notifyWaiters(_ sessionId: String) {
        guard var entry = entries[sessionId] else { return }
        let woken = entry.waiters
        entry.waiters = []
        entries[sessionId] = entry
        for wake in woken { wake(false) }
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

// MARK: - Connection-scoped pull table

/// One catalog pull a connection has running: the identity it was started
/// under and the cancellable task that carries it.
struct CommandPullJob {
    let token: CommandDirectory.CommandPullToken
    let task: Task<Void, Never>
}

/// The pulls of one Host connection, in a form the offline checks can drive.
///
/// The store's connection handling used to live entirely inside PocketStore,
/// which no offline check target compiles, so its defects could only be found
/// by reading: a queued pull was registered one task-hop late and the
/// connection identity was captured inside the task, so a pull queued before
/// a disconnect was neither in the table when the teardown drained it nor
/// aware of which connection it belonged to, and it went on to issue its RPC
/// against the next connection's transport. The pull table is therefore a
/// value the gate compiles, and its invariants are checked directly:
///
/// - `bind` is called synchronously by the directory's pull seam, so a pull
///   is in the table before its task can run, whatever the executor did
///   first;
/// - the connection identity is not a second counter that could drift from
///   the directory's: a token names the catalog generation it was minted
///   under, and a token whose generation is not the directory's current one
///   is work of a dead connection (`isStale`);
/// - `stop` cancels exactly those pulls and empties the table, so a queued
///   body observes its own cancellation and never touches the transport.
@MainActor
final class CommandPullConnection {
    private weak var directory: CommandDirectory?
    private(set) var jobs: [CommandDirectory.CommandPullToken: CommandPullJob] = [:]

    init(directory: CommandDirectory) {
        self.directory = directory
    }

    /// Register one pull and start it. The task handle is stored before the
    /// body can run, and the body removes it on every exit.
    func bind(_ token: CommandDirectory.CommandPullToken,
              _ body: @escaping @MainActor () async -> Void) {
        let job = CommandPullJob(token: token, task: Task { @MainActor in
            await body()
            self.jobs.removeValue(forKey: token)
        })
        jobs[token] = job
    }

    /// Whether one identity belongs to a connection that is no longer the
    /// directory's current one. Re-checked after every suspension, and
    /// before the transport is touched.
    func isStale(_ token: CommandDirectory.CommandPullToken) -> Bool {
        guard let directory else { return true }
        return !directory.isCurrent(token)
    }

    /// Whether the session key still exists in the directory's current
    /// generation. A session that was only ever pulled by the dead
    /// connection has no entry at all, which is already not current.
    func hasEntry(_ sessionId: String) -> Bool {
        directory?.currentToken(sessionId) != nil
    }

    /// Tear the connection down: cancel every pull it still has and empty
    /// the table. The directory's own `removeAll` is the caller's to run
    /// (it opens the new generation every token above then fails).
    func stop() {
        for job in jobs.values { job.task.cancel() }
        jobs.removeAll()
    }
}

// MARK: - Invalidation events

/// The events the reference client wires to the directory
/// (dsh-client-ui-commands client.js:537-545). Keeping them as values lets the
/// offline checks assert the cache decision without a transport.
enum CommandCatalogEvent: Equatable {
    /// `commands/change`, no args: a registry mutation may affect any session.
    case commandsChanged
    /// `agent-preset/selected`, args [sessionId, presetId]: one session's
    /// effective composition changed.
    case agentPresetSelected(sessionId: String)
    /// `connection/reset`: the transport (re)connected, so every snapshot is
    /// suspect (dsh-api-gateway client.js:1433 emits it on connect).
    case connectionReset
}

extension CommandDirectory {
    /// Apply one wired event, mirroring the reference's three registrations
    /// one for one: soft invalidation of every touched key, one session's
    /// reset, or the hard reset of every key.
    func apply(_ event: CommandCatalogEvent) {
        switch event {
        case .commandsChanged: invalidateAll()
        case .agentPresetSelected(let sessionId): resetSession(sessionId)
        case .connectionReset: resetConnected()
        }
    }
}

/// The catalog decision one `$events` emit frame carries, or nil when the
/// frame is not a catalog invalidation. The store wires the transport straight
/// to this, so the reference's three registrations stay checkable without the
/// store (which the offline gates cannot compile).
func commandCatalogEvent(name: String, args: [JSON]) -> CommandCatalogEvent? {
    switch name {
    case "commands/change": return .commandsChanged
    case "agent-preset/selected": return args.count == 2 ? .agentPresetSelected(sessionId: args[0].string) : nil
    default: return nil
    }
}

/// The reference `matchEnter` claim decision once the catalog is servable: the
/// command path owns the line only when its name resolves and the command
/// either declares an input line or the line is its bare token
/// (dsh-client-ui-commands client.js:747-752). An unknown name (client.js:735)
/// and trailing arguments on a command that declares no input line
/// (client.js:751) are not claimed, so the ordinary message path owns them. The
/// one outcome that is never downgraded is a warmup failure, which is reported
/// before this decision is reached.
func commandClaimsLine(_ line: String, descriptor: CommandDescriptor?) -> Bool {
    guard let descriptor else { return false }
    return descriptor.input != nil || !line.contains(where: { $0.isWhitespace })
}

// The durable command lifecycle fold lives in HarnessProtocol.swift, next to
// Transcript.rows, which consumes it: that file also compiles without this one
// (scripts/check-protocol.sh, scripts/check-native.sh).
