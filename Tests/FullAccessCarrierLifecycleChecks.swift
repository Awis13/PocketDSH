import Foundation

// DSH-INTEGRATION-1: the carrier's failure and ready edges drop a pending
// full-access confirmation, driven through the production seam the store uses.
//
// The acceptance gap this closes: FullAccessConfirmationChecks and
// HarnessStreamChecks were byte-identical to the accepted source heads, and
// neither ever executed the combined carrier -> confirmation path together -
// "existing isolated gate tests don't execute the newly combined carrier ->
// pending-confirmation invalidation." These checks do, in one file:
//
//   1. a pending escalation asked while the carrier connects - the socket fails
//      and the carrier will not reconnect - the seam drops the pending and a late
//      still-applies confirm dispatches nothing;
//   2. a pending escalation asked while the carrier is between a failed attempt
//      and its reconnect - the ready of the new attempt drops it, so a late
//      confirm dispatches nothing;
//   3. the routing decision - the escalation to the gate, the compact line to a
//      frozen server dispatch - counted with the frozen dispatch and the draft.
//
// Every assertion drives the production values the store itself uses - the real
// `RemoteStreamConnection.run` loop, the production `ConfirmationLifecycle` seam
// wired to a real `FullAccessGate`, and `resolveCommandDispatch` - never a copy
// of them, so "the carrier dropped the question" is proved on the same objects
// the store drives.

/// The carrier socket the offline checks substitute: it records the open frames
/// the real carrier loop sends, so a body that never ran is not mistaken for a
/// ready one.
@MainActor
final class ProbeTransport: RemoteStreamTransport {
    private(set) var frames: [JSON] = []
    func sendFrame(_ frame: JSON) async throws { frames.append(frame) }
    func ping() async throws {}
}

/// One parked continuation: the carrier loop's backoff `sleep` parks on it, so the
/// test can set a pending confirmation exactly while the carrier sits between a
/// failed attempt and its reconnect - the window the ready edge has to cover.
@MainActor
final class Park {
    private(set) var isParked = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        isParked = true
        await withCheckedContinuation { self.continuation = $0 }
    }
    func release() {
        if let continuation { continuation.resume(); self.continuation = nil }
    }
}

@main struct FullAccessCarrierLifecycleChecks {
    static let host = "https://dsn.example"
    static func json(_ s: String) -> JSON { try! JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }

    /// A catalog row: `input` nil means the command declares no input line.
    static func descriptor(_ name: String, input: Bool = false, hint: String = "<preset>", attachments: Bool? = nil) -> CommandDescriptor {
        guard input else { return CommandDescriptor(json(#"{"name":"\#(name)","description":"d"}"#)) }
        let flag = attachments.map { ",\"attachments\":\($0)" } ?? ""
        return CommandDescriptor(json(#"{"name":"\#(name)","description":"d","input":{"hint":"\#(hint)"\#(flag)}}"#))
    }
    static var permissionRow: CommandDescriptor { descriptor("permission", input: true) }
    /// The catalog a DSH session serves: the escalation plus ordinary commands.
    static var catalog: [CommandDescriptor] {
        [permissionRow, descriptor("compact", input: true, hint: "compact [reason]", attachments: true), descriptor("goal"), descriptor("help")]
    }
    static func composer(draft: String, images: [OutgoingImage] = [], session: String = "s1",
                         endpoint: String = host, generation: Int = 1, version: Int = 0) -> ComposerSubmission {
        ComposerSubmission(draft: draft, images: images, sessionID: session, endpoint: endpoint,
                           catalogGeneration: generation, draftVersion: version)
    }
    static func live(session: String? = "s1", endpoint: String = host, generation: Int = 1) -> LiveConnectionIdentity {
        LiveConnectionIdentity(sessionID: session, endpoint: endpoint, catalogGeneration: generation)
    }
    static func conversationArgs(_ sessionId: String) -> [String: JSON] {
        ["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(sessionId)]), "maxMessages": .number(50)])]
    }

    /// The store's `commands/execute` leg, recorded on the wire shape.
    @MainActor
    final class Recorder {
        private(set) var calls: [[String: JSON]] = []
        func execute(_ snapshot: ComposerSubmission, _ descriptor: CommandDescriptor) async {
            let submitted = submissionAttachments(snapshot.images) ?? []
            calls.append(commandExecuteArguments(agentId: snapshot.sessionID, line: snapshot.text, submittedAttachments: submitted))
        }
        var lines: [String] { calls.map { $0["line"]?.string ?? "" } }
    }

    /// Poll a condition until it holds, so the carrier loop and the test interleave
    /// deterministically instead of racing on a fixed delay.
    @MainActor
    static func spin(_ reached: () -> Bool) async {
        let deadline = Date().addingTimeInterval(20)
        while !reached() {
            assert(Date() < deadline, "the carrier never reached the state the test expected")
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do {
            try await failureDropsPending()
            try await readyDropsPending()
            try await routingFrozenDispatch()
            try await chipAsksNothingBeforeConfirm()
            try await chipCancelFreesSeatAndSendsNothing()
            try await chipConfirmSendsFrozenExactlyOnce()
            try await chipDoubleConfirmSendsOnce()
            try await chipSwitchDropsQuestionAndSeat()
            try await chipReconnectDropsQuestionAndSeat()
            try await rosterRepullDropsQuestionAndSeat()
            try await capabilityRemovalDropsQuestionAndSeat()
            try await lateAnswerKeepsNewerQuestion()
            try await approvalStillAnswersAllowedOnce()
            try await approvalQuestionRefusesChipClick()
            print("PASS: the carrier's failure and ready edges drop a pending confirmation")
            exit(0)
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    // (1) A pending escalation asked while the carrier connects: the socket fails
    // and the carrier will not reconnect, so the seam drops the pending and a late
    // still-applies confirm - same session, endpoint and catalog generation -
    // dispatches nothing. Sensitive to `carrierFailed`.
    @MainActor
    static func failureDropsPending() async throws {
        let carrier = RemoteStreamConnection()
        let transport = ProbeTransport()
        let gate = FullAccessGate()
        let lifecycle = ConfirmationLifecycle(gate)
        let snapshot = composer(draft: "/permission danger-full-access")
        guard let asked = gate.request(.command(snapshot, permissionRow)) else {
            return assert(false, "the escalation is pending while the carrier connects")
        }
        await carrier.run(attempts: 1, sleep: { _ in }, body: { _ in
            _ = try await carrier.subscribe(.conversation, endpoint: "session/follow", args: conversationArgs("s1"), on: transport)
            throw HarnessError(message: "the socket died before any reconnect")
        }, onAttempt: { _ in }, onFailure: { _, _ in lifecycle.carrierFailed() }, onFinish: {})
        assert(transport.frames.count == 1, "the carrier's body ran and opened its stream")
        assert(gate.pending == nil, "a carrier failure with no reconnect drops the pending confirmation")
        let recorder = Recorder()
        let outcome = await gate.confirm(id: asked.id, live: live(), busy: false,
                                         command: { await recorder.execute($0, $1) }, approval: { _ in },
                                         control: { _ in })
        assert(outcome == .rejected && recorder.calls.isEmpty, "a late confirmation to a dead carrier dispatches nothing")
        print("PASS: a failed carrier with no reconnect drops the pending confirmation")
    }

    // (2) A pending escalation asked while the carrier is between a failed attempt
    // and its reconnect: the ready of the new attempt drops it, so a late
    // still-applies confirm dispatches nothing. Sensitive to `attemptReady`.
    @MainActor
    static func readyDropsPending() async throws {
        let carrier = RemoteStreamConnection()
        let transport = ProbeTransport()
        let gate = FullAccessGate()
        let lifecycle = ConfirmationLifecycle(gate)
        let backoff = Park()
        var pendingID: UUID?
        let run = Task {
            await carrier.run(attempts: 2, sleep: { _ in await backoff.wait() }, body: { attempt in
                _ = try await carrier.subscribe(.conversation, endpoint: "session/follow", args: conversationArgs("s1"), on: transport)
                if attempt.index == 2 { lifecycle.attemptReady() }
                if attempt.index == 1 { throw HarnessError(message: "the first attempt died") }
            }, onAttempt: { _ in }, onFailure: { _, _ in lifecycle.carrierFailed() }, onFinish: {})
        }
        await spin { backoff.isParked }
        // The user asks for full access while the carrier is reconnecting:
        pendingID = gate.request(.command(composer(draft: "/permission danger-full-access"), permissionRow))?.id
        assert(pendingID != nil, "the escalation is pending while the carrier reconnects")
        assert(gate.pending != nil, "the pending is still live in the gap between the failed attempt and its reconnect")
        // The reconnect lands: the ready of the new attempt drops the old confirmation.
        backoff.release()
        await run.value
        assert(transport.frames.count == 2, "the reconnect's attempt ran and opened its stream")
        assert(gate.pending == nil, "the ready of a new attempt drops the pending confirmation")
        let recorder = Recorder()
        let outcome = await gate.confirm(id: pendingID!, live: live(), busy: false,
                                         command: { await recorder.execute($0, $1) }, approval: { _ in },
                                         control: { _ in })
        assert(outcome == .rejected && recorder.calls.isEmpty, "a late confirmation to a ready new attempt dispatches nothing")
        print("PASS: the ready of a new attempt drops the pending confirmation")
    }

    // (3) The routing decision and its frozen dispatch, in the same integration:
    // the escalation routes to the gate and the compact line to a frozen server
    // dispatch; cancel is nothing with the draft kept, confirm is exactly one
    // frozen dispatch with the sent line cleaned up by the send's own rule.
    @MainActor
    static func routingFrozenDispatch() async throws {
        guard case .confirmFullAccess(let escalation) = resolveCommandDispatch(composer(draft: "/permission danger-full-access"), descriptors: catalog) else {
            return assert(false, "the claimed escalation routes to the gate")
        }
        assert(escalation.name == "permission")
        guard case .execute(let compact) = resolveCommandDispatch(composer(draft: "/compact"), descriptors: catalog) else {
            return assert(false, "a bare /compact routes to a frozen server dispatch on DSH")
        }
        assert(compact.name == "compact")

        let recorder = Recorder()
        // The compact line is one frozen dispatch carrying its frozen line.
        let compactSnapshot = composer(draft: "/compact")
        await recorder.execute(compactSnapshot, compact)
        assert(recorder.calls.count == 1 && recorder.lines == ["/compact"], "the compact line is one frozen dispatch")

        // The escalation dispatches only from the gate's answer. The user's line
        // is a write, and the snapshot freezes at that write's version - the
        // store's own rule - so the send's cleanup below sees the line it sent.
        let gate = FullAccessGate()
        let line = "/permission danger-full-access"
        var drafts = ComposerDrafts()
        drafts.write(line, for: "s1")
        let snapshot = composer(draft: line, version: drafts.version(of: "s1"))
        guard let asked = gate.request(.command(snapshot, escalation)) else {
            return assert(false, "the escalation opens its confirmation")
        }
        assert(recorder.calls.count == 1, "opening the confirmation dispatches nothing")
        assert(gate.cancel(id: asked.id) && gate.pending == nil, "canceling drops the pending action")
        assert(recorder.calls.count == 1, "canceling the escalation dispatches nothing")
        assert(drafts.lines["s1"] == line, "canceling keeps the draft the user sent")
        guard let reasked = gate.request(.command(snapshot, escalation)) else {
            return assert(false, "the route is free again after the cancel")
        }
        let outcome = await gate.confirm(id: reasked.id, live: live(), busy: false,
                                         command: { await recorder.execute($0, $1) }, approval: { _ in },
                                         control: { _ in })
        assert(outcome == .dispatched && recorder.calls.count == 2 && recorder.lines == ["/compact", line],
               "confirming dispatches exactly one frozen line to the frozen session")
        let sent = drafts.applySent(snapshot, liveSession: "s1", liveDraft: line)
        assert(sent.forgotSavedLine && sent.liveDraft == "" && drafts.lines["s1"] == "",
               "the confirmed send clears only the line it sent")
        print("PASS: routing reaches the gate and the frozen dispatch, with cancel/confirm counts and the draft")
    }

    // MARK: - C2: the control chip on the production store

    // The chip's escalation runs the store's own paths - selectPermission
    // freezes the context and opens the shared question, confirmFullAccess and
    // cancelFullAccess run the seat and the wire - so the fixture below is the
    // C1 session-control infra, duplicated the way every offline gate keeps
    // its file compiling standalone.

    /// One parked rpc: the transport's call suspends on it until the test
    /// resumes it, so the request and the response are two orderable steps.
    @MainActor
    final class ParkedCall {
        let method: String
        let args: [String: JSON]
        fileprivate var continuation: CheckedContinuation<JSON, Error>?
        init(_ method: String, _ args: [String: JSON]) { self.method = method; self.args = args }
        func respond(_ value: JSON) { continuation?.resume(returning: value); continuation = nil }
        func fail(_ error: Error) { continuation?.resume(throwing: error); continuation = nil }
    }

    /// The delayed fake transport: every rpc parks until the test resumes it.
    @MainActor
    final class DeferredTransport {
        private(set) var parked: [ParkedCall] = []
        func rpc(_ method: String, args: [String: JSON]) async throws -> JSON {
            let call = ParkedCall(method, args)
            parked.append(call)
            return try await withCheckedThrowingContinuation { call.continuation = $0 }
        }
        /// The parked calls of one method, in arrival order.
        func calls(_ method: String) -> [ParkedCall] { parked.filter { $0.method == method } }
    }

    /// HarnessAPI on the parked transport: production rpc, held wire.
    @MainActor
    final class FakeAPI: HarnessAPI {
        let transport = DeferredTransport()
        init() { super.init(base: URL(string: "https://dsn.example")!) }
        override func rpc(_ method: String, args: [String: JSON]) async throws -> JSON {
            try await transport.rpc(method, args: args)
        }
    }

    /// A session row carrying the Host's projection section, shaped as the
    /// session list serves it.
    @MainActor
    static func projected(_ id: String, blank: Bool = true, running: Bool = false) -> HarnessSession {
        let values: [String: JSON] = ["sessionListMetadata": .object(["blank": .bool(blank)])]
        return HarnessSession(raw: .object([
            "sessionId": .string(id), "cwd": .string("/w"), "updatedAt": .number(1),
            "running": .bool(running),
            "projections": .object(["values": .object(values)])
        ]))
    }

    /// Wire one production store to a parked transport, already connected.
    @MainActor
    static func wire(_ store: PocketStore, _ api: FakeAPI, sessions: [String]) {
        store.endpoint = "https://dsn.example"
        store.api = api
        store.connected = true
        store.sessions = sessions.map { projected($0) }
    }

    /// One permissions projection, shaped exactly as dsh-permission-presets
    /// serves it: the option rows and the current value.
    @MainActor
    static func permProjection(currentValue: String, options: [String]) -> JSON {
        .object([
            "options": .array(options.map { .object(["value": .string($0), "name": .string($0)]) }),
            "currentValue": .string(currentValue)
        ])
    }

    /// One plan projection, shaped as dsh-plan-mode serves it.
    @MainActor
    static func planProjection(active: Bool, pending: Bool) -> JSON {
        .object(["active": .bool(active), "pending": .bool(pending)])
    }

    /// Seed one session's fold store the way the session/control delivery
    /// path writes it: the same apply the production frame handler calls.
    /// An absent projection is a missing capability, exactly as the store
    /// reads it.
    @MainActor
    static func seed(_ store: PocketStore, _ id: String, permissions: JSON? = nil, plan: JSON? = nil) {
        var fold = SessionProjectionStore()
        var seq = 0
        if let permissions { seq += 1; fold.apply(key: ProjectionKey.permissions, value: permissions, seq: seq) }
        if let plan { seq += 1; fold.apply(key: ProjectionKey.plan, value: plan, seq: seq) }
        store.projectionStores[id] = fold
    }

    /// One command descriptor, shaped as commands/list serves it.
    @MainActor
    static func rawCommand(_ name: String) -> [String: JSON] {
        ["name": .string(name), "description": .string(name)]
    }

    /// Answer the catalog pull the production select already parked - or
    /// warm a cold key after a reconnect dropped the old snapshot - and wait
    /// for the directory to be ready.
    @MainActor
    /// A second session warmed on the same transport must wait for its own
    /// pull: the count is cumulative, so the spin keys on the calls added
    /// after this warm, and only those are answered.
    static func warmCatalog(_ store: PocketStore, _ api: FakeAPI, _ id: String, _ commands: [[String: JSON]]) async {
        let before = api.transport.calls("commands/list").count
        store.commandDirectory.warm(id)
        await spin { api.transport.calls("commands/list").count > before || store.commandDirectory.status(id) == .ready }
        if store.commandDirectory.status(id) == .ready { return }
        let calls = api.transport.calls("commands/list")
        calls[calls.count - 1].respond(.array(commands.map { .object($0) }))
        await spin { store.commandDirectory.status(id) == .ready }
    }

    /// One composer image the invariants must come back byte for byte.
    @MainActor
    static func img() -> OutgoingImage {
        OutgoingImage(id: UUID(), data: Data([1, 2, 3]), mediaType: "image/png", name: "a.png")
    }

    /// The commands/execute success the Host answers with.
    @MainActor
    static func execSuccess() -> JSON {
        .object(["commandId": .string("c1"), "result": .object(["kind": .string("success"), "text": .string("ok")])])
    }

    /// The n-th parked commands/execute (1-based), held until the test resumes it.
    @MainActor
    static func parkedExecute(_ api: FakeAPI, _ n: Int = 1) async -> ParkedCall {
        await spin { api.transport.calls("commands/execute").count >= n }
        return api.transport.calls("commands/execute")[n - 1]
    }

    /// The n-th parked call of one method (1-based), held until resumed.
    @MainActor
    static func parkedCall(_ api: FakeAPI, _ method: String, _ n: Int = 1) async -> ParkedCall {
        await spin { api.transport.calls(method).count >= n }
        return api.transport.calls(method)[n - 1]
    }

    /// A session/list response carrying each row's accepted preset ("" = the
    /// deployment default) and blank fact, exactly as the projection section
    /// of the list serves them.
    @MainActor
    static func projectedList(_ items: [(id: String, preset: String, blank: Bool)]) -> JSON {
        let rows: [JSON] = items.map { spec in
            var values: [String: JSON] = ["sessionListMetadata": .object(["blank": .bool(spec.blank)])]
            if !spec.preset.isEmpty { values["agentPreset"] = .string(spec.preset) }
            return .object([
                "sessionId": .string(spec.id), "cwd": .string("/w"), "updatedAt": .number(1),
                "running": .bool(false),
                "projections": .object(["values": .object(values)])
            ])
        }
        return .object(["items": .array(rows)])
    }

    /// One approval request as the live stream serves it. The store's offline
    /// client id is the empty string, and the answer guard checks it.
    static func approvalRequest(_ id: String = "e1", session: String = "sA") -> Interaction {
        Interaction(raw: json(#"{"event":"approval/request","eventId":"\#(id)","agentId":"\#(session)","request":{"toolName":"bash"}}"#), clientID: "")
    }

    // (4) C2: the permission chip's escalation opens the shared question and
    // asks nothing before the answer: no commands/execute, no prompt, the
    // composer keeps its draft and images, the seat is held by the frozen
    // operation, and the routing outcome is published.
    @MainActor
    static func chipAsksNothingBeforeConfirm() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await warmCatalog(store, api, "sA", [rawCommand("permission")])
        store.draft = "the draft the user is editing"
        store.images = [img()]
        await store.selectPermission(FullAccessPolicy.presetName)
        assert(store.accessConfirmation != nil, "the chip's escalation opens the shared question")
        assert(store.activeControl != nil, "the chip keeps the store seat while the question is open")
        assert(store.controlOutcome == .routedToFullAccess, "the routing outcome is published")
        assert(api.transport.calls("commands/execute").count == 0, "nothing leaves before the confirmation")
        assert(api.transport.calls("session/prompt").count == 0, "and no prompt")
        assert(store.draft == "the draft the user is editing" && store.images.count == 1, "the composer is untouched")
    }

    // (5) C2: a cancelled chip question frees the seat and sends nothing;
    // the next click takes a fresh freeze, never a chair already occupied.
    @MainActor
    static func chipCancelFreesSeatAndSendsNothing() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await warmCatalog(store, api, "sA", [rawCommand("permission")])
        store.draft = "the draft the user is editing"
        await store.selectPermission(FullAccessPolicy.presetName)
        guard let pending = store.accessConfirmation else { return assert(false, "the question opened") }
        store.cancelFullAccess(pending.id)
        assert(store.accessConfirmation == nil, "the cancel closes the question")
        assert(store.activeControl == nil, "and frees the seat")
        assert(store.controlOutcome == nil, "the routing outcome goes with the lineage")
        assert(api.transport.calls("commands/execute").count == 0, "nothing was sent")
        assert(store.draft == "the draft the user is editing", "and the draft survived")
        await store.selectPermission(FullAccessPolicy.presetName)
        assert(store.accessConfirmation != nil && store.activeControl != nil, "the next chip click opens its own question")
    }

    // (6) C2: a confirmed chip question sends the frozen line for the frozen
    // session exactly once, and the composer edits that keep the question open
    // never leak into the wire: no draft, no images, no cleanup.
    @MainActor
    static func chipConfirmSendsFrozenExactlyOnce() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await warmCatalog(store, api, "sA", [rawCommand("permission")])
        store.draft = "a draft the user is editing"
        store.images = [img()]
        await store.selectPermission(FullAccessPolicy.presetName)
        guard let pending = store.accessConfirmation else { return assert(false, "the question opened") }
        let task = Task { @MainActor in await store.confirmFullAccess(pending.id) }
        let call = await parkedExecute(api)
        // The user keeps typing while the answer travels: the wire must be the
        // freeze the click made, not the composer as it is now.
        store.draft = "a draft the user kept editing"
        store.images = [img(), img()]
        assert(call.args == ["agentId": .string("sA"), "line": .string(FullAccessPolicy.commandLine), "submittedAttachments": .array([])],
               "the wire is the frozen line for the frozen session, with no attachments")
        call.respond(execSuccess())
        await task.value
        assert(store.controlOutcome == .sent(line: FullAccessPolicy.commandLine), "the ack settles the sent line")
        assert(store.error == nil, "a success writes no error")
        assert(store.activeControl == nil, "the seat is released")
        assert(store.draft == "a draft the user kept editing" && store.images.count == 2, "the composer kept its draft and images")
        assert(api.transport.calls("commands/execute").count == 1, "exactly one send")
    }

    // (7) C2: a doubled confirm answers nothing the second time - the question
    // is withdrawn before the first answer even parks - and the wire carries
    // exactly one frozen send.
    @MainActor
    static func chipDoubleConfirmSendsOnce() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await warmCatalog(store, api, "sA", [rawCommand("permission")])
        await store.selectPermission(FullAccessPolicy.presetName)
        guard let pending = store.accessConfirmation else { return assert(false, "the question opened") }
        let first = Task { @MainActor in await store.confirmFullAccess(pending.id) }
        let second = Task { @MainActor in await store.confirmFullAccess(pending.id) }
        let call = await parkedExecute(api)
        call.respond(execSuccess())
        await first.value
        await second.value
        assert(api.transport.calls("commands/execute").count == 1, "the double confirm sent once")
        assert(store.controlOutcome == .sent(line: FullAccessPolicy.commandLine), "the settle is the sent line")
        assert(store.error == nil && store.activeControl == nil, "and the seat is clean")
    }

    // (8) C2: a session switch drops a pending chip question and its seat, so
    // the replaced session's answer can never land on the new one.
    @MainActor
    static func chipSwitchDropsQuestionAndSeat() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        store.sessions = [projected("sA"), projected("sB")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await warmCatalog(store, api, "sA", [rawCommand("permission")])
        await store.selectPermission(FullAccessPolicy.presetName)
        assert(store.accessConfirmation != nil, "the question opened")
        await store.select("sB")
        assert(store.accessConfirmation == nil, "a session switch drops the question")
        assert(store.activeControl == nil, "and frees the seat")
        assert(store.controlOutcome == nil, "and the routing outcome goes with it")
        assert(api.transport.calls("commands/execute").count == 0, "nothing was sent")
    }

    // (9) C2: a reconnect drops a pending chip question and its seat the same
    // way, and the new connection's click opens a fresh question that
    // confirms to the new transport.
    @MainActor
    static func chipReconnectDropsQuestionAndSeat() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await warmCatalog(store, api, "sA", [rawCommand("permission")])
        await store.selectPermission(FullAccessPolicy.presetName)
        assert(store.accessConfirmation != nil, "the question opened")
        store.disconnect()
        assert(store.accessConfirmation == nil, "a disconnect drops the question")
        assert(store.activeControl == nil, "and frees the seat")
        let api2 = FakeAPI()
        store.api = api2
        store.connected = true
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await warmCatalog(store, api2, "sA", [rawCommand("permission")])
        await store.selectPermission(FullAccessPolicy.presetName)
        guard let pending = store.accessConfirmation else { return assert(false, "the new connection's click opens its question") }
        let task = Task { @MainActor in await store.confirmFullAccess(pending.id) }
        let call = await parkedExecute(api2)
        assert(call.args["agentId"] == .string("sA") && call.args["line"] == .string(FullAccessPolicy.commandLine), "the frozen line rides the new transport")
        call.respond(execSuccess())
        await task.value
        assert(store.controlOutcome == .sent(line: FullAccessPolicy.commandLine), "the new connection settles the sent line")
        assert(api.transport.calls("commands/execute").count == 0, "the dead connection sent nothing")
    }

    // (10) C2: a re-asked agentPresets/list retires a pending chip question -
    // the roster the freeze named is not the roster the store holds anymore -
    // and frees the seat for the next click.
    @MainActor
    static func rosterRepullDropsQuestionAndSeat() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await warmCatalog(store, api, "sA", [rawCommand("permission")])
        await store.selectPermission(FullAccessPolicy.presetName)
        assert(store.accessConfirmation != nil, "the question opened")
        let task = Task { @MainActor in await store.refreshPresetRoster() }
        await spin { store.accessConfirmation == nil }
        assert(store.activeControl == nil, "the seat goes with the question")
        assert(store.controlOutcome == nil, "and the routing outcome")
        let roster = await parkedCall(api, "agentPresets/list")
        roster.respond(.object(["presets": .array([]), "authorable": .bool(false)]))
        await task.value
        await store.selectPermission(FullAccessPolicy.presetName)
        assert(store.accessConfirmation != nil, "the next click opens its own question on the new roster")
    }

    // (11) C2: a baseline fold that drops the permissions projection retires
    // a pending chip question with its seat, and the next click settles the
    // missing capability instead of asking.
    @MainActor
    static func capabilityRemovalDropsQuestionAndSeat() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]),
             plan: planProjection(active: false, pending: false))
        await warmCatalog(store, api, "sA", [rawCommand("permission")])
        await store.selectPermission(FullAccessPolicy.presetName)
        assert(store.accessConfirmation != nil, "the question opened")
        store.applyProjection("sA", p: .object(["asOfSeq": .number(10), "values": .object(["plan": planProjection(active: false, pending: false)])]))
        assert(store.projectionStores["sA"]?.permissions == nil, "the fold dropped the capability")
        assert(store.accessConfirmation == nil, "the fold retires the question")
        assert(store.activeControl == nil, "and frees the seat")
        assert(store.controlOutcome == nil, "and the routing outcome")
        await store.selectPermission(FullAccessPolicy.presetName)
        assert(store.accessConfirmation == nil, "no capability, no question")
        assert(store.controlOutcome == .capabilityMissing(.permissionProjection), "the click settles the missing capability")
        assert(api.transport.calls("commands/execute").count == 0, "and nothing was sent")
    }

    // (12) C2: a confirmed answer that parks across a session switch finds the
    // seat taken by the newer question - it writes no outcome and no error for
    // the question it no longer owns, and the newer question still settles on
    // its own session.
    @MainActor
    static func lateAnswerKeepsNewerQuestion() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        store.sessions = [projected("sA"), projected("sB")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await warmCatalog(store, api, "sA", [rawCommand("permission")])
        await store.selectPermission(FullAccessPolicy.presetName)
        guard let firstQuestion = store.accessConfirmation else { return assert(false, "the first question opened") }
        let first = Task { @MainActor in await store.confirmFullAccess(firstQuestion.id) }
        let call = await parkedExecute(api, 1)
        await store.select("sB")
        seed(store, "sB", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await warmCatalog(store, api, "sB", [rawCommand("permission")])
        await store.selectPermission(FullAccessPolicy.presetName)
        guard let secondQuestion = store.accessConfirmation, secondQuestion.id != firstQuestion.id else {
            return assert(false, "the newer session's click opens its own question")
        }
        call.respond(execSuccess())
        await spin { !store.submitting }
        assert(store.accessConfirmation?.id == secondQuestion.id, "the late answer kept the newer question")
        assert(store.activeControl != nil, "and its seat")
        assert(store.controlOutcome == .routedToFullAccess, "and the newer question still owns the routing outcome")
        let second = Task { @MainActor in await store.confirmFullAccess(secondQuestion.id) }
        let secondCall = await parkedExecute(api, 2)
        assert(secondCall.args["agentId"] == .string("sB"), "the newer question sends to the newer session")
        secondCall.respond(execSuccess())
        await second.value
        assert(store.controlOutcome == .sent(line: FullAccessPolicy.commandLine), "the newer question settles")
        await first.value
        assert(api.transport.calls("commands/execute").count == 2, "each question sent exactly once")
    }

    // (13) C2: the approval card still answers the request it sits on: the
    // confirmed enable rides the frozen session, the refresh it rides, and the
    // allowed-once answer that follows it.
    @MainActor
    static func approvalStillAnswersAllowedOnce() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        store.interactions = [approvalRequest()]
        assert(store.requestFullAccess(.approval(store.interactions[0])), "the card's question opens")
        guard let pending = store.accessConfirmation else { return assert(false, "the card's question opened") }
        let task = Task { @MainActor in await store.confirmFullAccess(pending.id) }
        let exec = await parkedExecute(api)
        assert(exec.args == ["agentId": .string("sA"), "line": .string(FullAccessPolicy.commandLine), "submittedAttachments": .array([])],
               "the enable rides the frozen session")
        exec.respond(execSuccess())
        let list = await parkedCall(api, "session/list")
        list.respond(projectedList([("sA", "", true)]))
        let answer = await parkedCall(api, "$events/result")
        assert(answer.args == ["clientId": .string(""), "eventId": .string("e1"),
                                "outcome": .object(["kind": .string("result"), "value": .string("allowed-once")])],
               "the card's confirmation answers the card allowed-once")
        answer.respond(.null)
        await task.value
        assert(store.interactions.isEmpty, "the answered card is removed")
    }

    // (14) C2: a chip click while the approval card's question is open takes
    // the seat no one, replaces no question, and publishes the routing outcome
    // it decided.
    @MainActor
    static func approvalQuestionRefusesChipClick() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await warmCatalog(store, api, "sA", [rawCommand("permission")])
        store.interactions = [approvalRequest()]
        assert(store.requestFullAccess(.approval(store.interactions[0])), "the card's question opens")
        guard let question = store.accessConfirmation else { return assert(false, "the card's question opened") }
        await store.selectPermission(FullAccessPolicy.presetName)
        assert(store.accessConfirmation?.id == question.id, "the chip's click did not replace the card's question")
        assert(store.activeControl == nil, "the chip's seat is refused and released")
        assert(store.controlOutcome == .routedToFullAccess, "and the routing outcome is still published")
        assert(api.transport.calls("commands/execute").count == 0, "and nothing was sent")
    }
}

