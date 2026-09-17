import Foundation

// PARITY-2C C3: the composer's session control chips, driven through the
// production store state the chips derive from - the same fold, gate and
// seat the dispatch freezes - and the production selectPermission,
// togglePlan, submit, answer and full-access paths on a parked transport.
//
// What the checks close:
//
//   * the surface is the DSH composer's - hidden on the Native harness and
//     while disconnected, visible on a connected DSH session;
//   * send and approval leave the surface alone - the projection is the only
//     writer of the state the chips show, and the approval still answers its
//     card allowed-once;
//   * the projection before and after the ack - a click is busy, not
//     accepted: the label stays the server's current value across the parked
//     answer, the success ack writes no projection, and the server's re-emit
//     is what moves the label and the checkmark;
//   * capability disappearance - a fold the Host stopped serving renders the
//     neutral chip, in flight as well as at rest, and releases the seat;
//   * the asking state is the open question, never the published outcome - a
//     chip click refused because the gate already shows the approval card's
//     question reads back as asking, and after the card's question closes the
//     stale routing outcome is not drawn as a new escalation;
//   * the menu rows come only from the projection's options - the custom row
//     is display-only, an unknown current value falls back to the value
//     itself with no checkmark;
//   * the plan chip - every active/pending combination reads back, the
//     pending and the in-flight toggle block re-toggling, and no full-access
//     question ever opens for it.
//
// The transport is the only fake: FakeAPI subclasses the production
// HarnessAPI on a parked transport, so the request and the response travel
// the production rpc path.

/// One parked rpc: the transport's call suspends on it until the test resumes
/// it, so the request and the response are two separate, orderable steps.
@MainActor
final class ParkedCall {
    let method: String
    let args: [String: JSON]
    fileprivate var continuation: CheckedContinuation<JSON, Error>?
    init(_ method: String, _ args: [String: JSON]) { self.method = method; self.args = args }
    func respond(_ value: JSON) { continuation?.resume(returning: value); continuation = nil }
    func fail(_ error: Error) { continuation?.resume(throwing: error); continuation = nil }
}

/// The delayed fake transport: every rpc parks until the test resumes it, so
/// a response can be held back across a parked answer - the exact window the
//  surface's busy and asking states exist for.
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

@main struct SessionControlSurfaceChecks {
    static func json(_ s: String) -> JSON { try! JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }

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

    /// Poll a condition until it holds, so the parked transport and the store
    /// interleave deterministically instead of racing on a fixed delay.
    @MainActor
    static func spin(_ reached: () -> Bool) async {
        let deadline = Date().addingTimeInterval(20)
        while !reached() {
            assert(Date() < deadline, "the store never reached the state the test expected")
            try? await Task.sleep(for: .milliseconds(2))
        }
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

    /// Wire one production store to a parked transport, already connected.
    @MainActor
    static func wire(_ store: PocketStore, _ api: FakeAPI, sessions: [String]) {
        store.endpoint = "https://dsn.example"
        store.api = api
        store.connected = true
        store.sessions = sessions.map { projected($0) }
    }

    // MARK: - The wire fixtures

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
    static func descriptor(_ name: String) -> [String: JSON] {
        ["name": .string(name), "description": .string(name)]
    }

    /// Answer the catalog pull the production select already parked - or
    /// warm a cold key after a reconnect dropped the old snapshot - and wait
    /// for the directory to be ready.
    @MainActor
    static func catalog(_ store: PocketStore, _ api: FakeAPI, _ id: String, _ commands: [[String: JSON]]) async {
        store.commandDirectory.warm(id)
        await spin { api.transport.calls("commands/list").count >= 1 || store.commandDirectory.status(id) == .ready }
        if store.commandDirectory.status(id) == .ready { return }
        let calls = api.transport.calls("commands/list")
        calls[calls.count - 1].respond(.array(commands.map { .object($0) }))
        await spin { store.commandDirectory.status(id) == .ready }
    }

    /// The commands/execute success the Host answers with.
    @MainActor
    static func execSuccess() -> JSON {
        .object(["commandId": .string("c1"), "result": .object(["kind": .string("success"), "text": .string("ok")])])
    }

    /// The n-th parked commands/execute (1-based), held until the test
    /// resumes it.
    @MainActor
    static func parkedExecute(_ api: FakeAPI, _ n: Int = 1) async -> ParkedCall {
        await spin { api.transport.calls("commands/execute").count >= n }
        return api.transport.calls("commands/execute")[n - 1]
    }

    /// The n-th parked call of one method (1-based), held until the test
    /// resumes it.
    @MainActor
    static func parkedCall(_ api: FakeAPI, _ method: String, _ n: Int = 1) async -> ParkedCall {
        await spin { api.transport.calls(method).count >= n }
        return api.transport.calls(method)[n - 1]
    }

    /// One approval card as the store receives it.
    static func approvalRequest(_ id: String = "e1", session: String = "sA") -> Interaction {
        Interaction(raw: json(#"{"event":"approval/request","eventId":"\#(id)","agentId":"\#(session)","request":{"toolName":"bash"}}"#), clientID: "")
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

    /// The chips' derived state: one read, the way the view reads it.
    @MainActor
    static func surface(_ store: PocketStore) -> SessionControlSurface {
        SessionControlSurface(store: store)
    }

    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do {
            try await surfaceIsTheDSHComposer()
            try await sendAndApprovalLeaveTheSurfaceAlone()
            try await projectionBeforeAndAfterAck()
            try await capabilityDisappearance()
            try await askingIsTheOpenQuestion()
            try await menuRowsComeOnlyFromTheProjection()
            try await planSurfaceAndBlocking()
            print("PASS: the composer's control chips read the server-owned state")
            exit(0)
        }
        catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    // (1) The chips are the DSH composer's: a connected DSH session shows
    // them, a disconnected store hides them, and the Native harness has no
    // host commands behind them.
    @MainActor
    static func surfaceIsTheDSHComposer() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        assert(surface(store).visible, "a connected DSH session shows the chips")
        store.connected = false
        assert(!surface(store).visible, "a disconnected store has no session to switch")
        store.connected = true
        store.endpoint = "ws://host:1234"
        assert(!surface(store).visible, "the Native harness has no host commands behind the chips")
        store.endpoint = "https://dsn.example"
        assert(surface(store).visible, "and the DSH session's chips are back")
        print("PASS: the chips are the DSH composer's")
    }

    // (2) Regression: a composer send and an approval card both leave the
    // chips' state alone - the projection is the only writer of it, the send
    // is the composer's own prompt, and the approval still answers its card
    // allowed-once.
    @MainActor
    static func sendAndApprovalLeaveTheSurfaceAlone() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA",
             permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]),
             plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        let before = surface(store)
        assert(before.visible && before.permission?.label == "read-only", "the chips read the seeded projection")

        // A composer send: the draft leaves on session/prompt, the surface is
        // untouched by it.
        store.draft = "hello"
        let send = Task { @MainActor in await store.submit() }
        let prompt = await parkedCall(api, "session/prompt")
        assert(prompt.args["request"]?["sessionId"].string == "sA", "addressed to the selected session")
        assert(prompt.args["request"]?["mode"].string == "queue", "queued like the composer's own send")
        assert(prompt.args["request"]?["content"] == .array([.object(["type": .string("text"), "text": .string("hello")])]),
               "and the draft left as the composer's own text part")
        prompt.respond(.null)
        await send.value
        assert(api.transport.calls("session/prompt").count == 1, "the draft left exactly once")
        assert(store.draft.isEmpty, "the sent draft is cleaned")
        let afterSend = surface(store)
        assert(afterSend.permission == before.permission && afterSend.plan == before.plan, "the send wrote no projection")
        assert(!afterSend.asking && !afterSend.busy, "the send takes no seat and asks nothing")

        // An approval card: the confirmed escalation enables, rides the
        // refresh, and answers the card allowed-once - and still leaves the
        // surface alone.
        store.interactions = [approvalRequest()]
        assert(store.requestFullAccess(.approval(store.interactions[0])), "the card's question opens")
        guard let pending = store.accessConfirmation else { return assert(false, "the card's question opened") }
        let confirm = Task { @MainActor in await store.confirmFullAccess(pending.id) }
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
        await confirm.value
        assert(store.interactions.isEmpty, "the answered card is removed")
        let afterApproval = surface(store)
        assert(afterApproval.permission == before.permission && afterApproval.plan == before.plan, "the approval wrote no projection")
        assert(!afterApproval.asking && !afterApproval.busy, "the approval's question closed and took no control seat")
        assert(api.transport.calls("session/prompt").count == 1, "the approval answered the card, not the composer")
        print("PASS: send and approval leave the chips' server-owned state alone")
    }

    // (3) The projection before and after the ack: the click is busy, not
    // accepted - the label stays the server's current value across the
    // parked answer, the success ack writes no projection, and the server's
    // re-emit is what moves the label and the checkmark.
    @MainActor
    static func projectionBeforeAndAfterAck() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        let options = ["read-only", "read-write", "danger-full-access"]
        seed(store, "sA",
             permissions: permProjection(currentValue: "read-only", options: options),
             plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        let foldBefore = store.projectionStores["sA"]

        let click = Task { @MainActor in await store.selectPermission("read-write") }
        let exec = await parkedExecute(api)
        assert(exec.args == ["agentId": .string("sA"), "line": .string("/permission read-write"), "submittedAttachments": .array([])],
               "the click sends its own line")
        let inFlight = surface(store)
        assert(inFlight.busy, "the click holds the seat")
        assert(inFlight.permission?.label == "read-only", "the staged choice is not drawn as accepted")
        assert(inFlight.permission?.currentRow?.value == "read-only", "and the checkmark stays on the server's value")

        exec.respond(execSuccess())
        await click.value
        let settled = surface(store)
        assert(!settled.busy, "the answer released the seat")
        assert(store.projectionStores["sA"] == foldBefore, "the success ack wrote no projection")
        assert(settled.permission?.label == "read-only", "so the label is still the server's value")

        // The server's re-emit is the only thing that moves it.
        store.projectionStores["sA"]?.apply(key: ProjectionKey.permissions,
                                            value: permProjection(currentValue: "read-write", options: options),
                                            seq: 99)
        let reEmitted = surface(store)
        assert(reEmitted.permission?.label == "read-write", "the re-emit moves the label")
        assert(reEmitted.permission?.currentRow?.value == "read-write", "and the checkmark")
        print("PASS: the ack writes no state and the server's re-emit is the writer")
    }

    // (4) Capability disappearance: a fold the Host stopped serving renders
    // the neutral chips, in flight as well as at rest, and the seat is
    // released with the stale answer.
    @MainActor
    static func capabilityDisappearance() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        let options = ["read-only", "read-write", "danger-full-access"]
        seed(store, "sA",
             permissions: permProjection(currentValue: "read-only", options: options),
             plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])

        // At rest: the fold is gone, the chips render the neutral state.
        store.projectionStores["sA"] = SessionProjectionStore()
        assert(surface(store).permission == nil && surface(store).plan == nil, "the stopped-serving fold renders neutral")

        // In flight: the capability leaves under a parked answer, and the
        // late success stales instead of writing over the gone projection.
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: options))
        let click = Task { @MainActor in await store.selectPermission("read-write") }
        let exec = await parkedExecute(api)
        assert(surface(store).busy, "the click holds its seat")
        store.projectionStores["sA"] = SessionProjectionStore()
        assert(surface(store).permission == nil && surface(store).plan == nil, "the fold is gone under the parked answer")
        assert(surface(store).busy, "and the seat still is")
        exec.respond(execSuccess())
        await click.value
        assert(!surface(store).busy, "the stale answer released the seat")
        assert(surface(store).permission == nil && surface(store).plan == nil, "and the chips stay neutral")
        print("PASS: capability disappearance renders the neutral chips and releases the seat")
    }

    // (5) The asking state is the open question, never the published outcome:
    // a chip click refused because the gate already shows the approval card's
    // question reads back as asking, and after the card's question closes the
    // stale routing outcome is not drawn as a new escalation.
    @MainActor
    static func askingIsTheOpenQuestion() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        let options = ["read-only", "read-write", "danger-full-access"]
        seed(store, "sA",
             permissions: permProjection(currentValue: "read-only", options: options),
             plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        store.interactions = [approvalRequest()]
        assert(store.requestFullAccess(.approval(store.interactions[0])), "the card's question opens")
        guard let question = store.accessConfirmation else { return assert(false, "the card's question opened") }

        // The chip click while the card's question is open: the gate refuses
        // the second question, the store publishes the routing outcome it
        // decided, and the chips read the open question - not the outcome.
        await store.selectPermission("danger-full-access")
        assert(store.controlOutcome == .routedToFullAccess, "the store publishes the routing outcome")
        assert(store.activeControl == nil, "and the seat is released")
        let asking = surface(store)
        assert(asking.asking, "the chips read the open question")
        assert(!asking.busy, "not their own seat")
        assert(asking.permission?.label == "read-only", "and the label stays the server's value")
        assert(api.transport.calls("commands/execute").count == 0, "and nothing was sent")

        // The card's question closes: the stale outcome outlives it in the
        // store, and the chips do not draw it as a new escalation.
        store.cancelFullAccess(question.id)
        assert(store.controlOutcome == .routedToFullAccess, "the outcome outlives the question in the store")
        let closed = surface(store)
        assert(!closed.asking, "the chips read the closed question")
        assert(!closed.busy, "and no seat")
        assert(closed.permission?.label == "read-only", "the label is still the server's value, not the escalation")
        print("PASS: the asking state is the open question, never the published outcome")
    }

    // (6) The menu rows come only from the projection's options: the custom
    // row is display-only, and an unknown current value falls back to the
    // value itself with no checkmark.
    @MainActor
    static func menuRowsComeOnlyFromTheProjection() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        let options = ["read-only", "read-write", "custom"]
        seed(store, "sA", permissions: permProjection(currentValue: "custom", options: options))
        guard let perm = surface(store).permission else { return assert(false, "the permission surface exists") }
        assert(perm.rows.map(\.value) == options, "the rows are the projection's options, in order")
        assert(perm.rows[0].selectable && perm.rows[1].selectable && !perm.rows[2].selectable, "the custom row is display-only")
        assert(perm.currentRow == perm.rows[2], "and it is the current value")
        assert(perm.label == "custom", "named by the projection")

        // The current value the projection no longer offers: the fallback is
        // the value itself, and no row carries the checkmark.
        store.projectionStores["sA"]?.apply(key: ProjectionKey.permissions,
                                            value: permProjection(currentValue: "workspace-write", options: options),
                                            seq: 99)
        guard let unknown = surface(store).permission else { return assert(false, "the permission surface exists") }
        assert(unknown.currentRow == nil, "no row names the unknown value")
        assert(unknown.label == "workspace-write", "the label falls back to the value itself")
        print("PASS: the menu is the projection's own options, custom display-only, unknown values falling back")
    }

    // (7) The plan chip: every active/pending combination reads back, the
    // in-flight toggle blocks re-toggling on the shared seat, no full-access
    // question opens for it, and the ack writes no projection.
    @MainActor
    static func planSurfaceAndBlocking() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        for active in [false, true] {
            for pending in [false, true] {
                seed(store, "sA", plan: planProjection(active: active, pending: pending))
                assert(surface(store).plan == SessionControlSurface.Plan(active: active, pending: pending),
                       "the surface mirrors active=\(active) pending=\(pending)")
            }
        }

        seed(store, "sA", plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("plan")])
        let toggle = Task { @MainActor in await store.togglePlan() }
        let exec = await parkedExecute(api)
        assert(exec.args == ["agentId": .string("sA"), "line": .string("/plan"), "submittedAttachments": .array([])],
               "the toggle sends its exact line")
        let inFlight = surface(store)
        assert(inFlight.planInFlight, "the in-flight toggle is drawn")
        assert(inFlight.busy, "and it takes the seat")
        assert(store.accessConfirmation == nil, "the toggle asks no full-access question")
        let second = Task { @MainActor in await store.togglePlan() }
        await second.value
        assert(api.transport.calls("commands/execute").count == 1, "the seat refused the second toggle")
        exec.respond(execSuccess())
        await toggle.value
        let settled = surface(store)
        assert(settled.plan == SessionControlSurface.Plan(active: false, pending: false), "the ack wrote no projection")
        assert(!settled.planInFlight && !settled.busy, "and the seat is free")
        print("PASS: the plan chip mirrors the projection and blocks re-toggling without a confirmation")
    }
}
