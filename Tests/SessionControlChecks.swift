import Foundation

// PARITY-2C C1: the permission preset switch and the plan-mode toggle,
// driven through the production PocketStore.selectPermission and
// PocketStore.togglePlan - the same full-store closure PresetSelectionChecks
// compiles, so the freeze, the decision order and the wire shape are the
// production ones, not a copy of them.
//
// What the checks close:
//
//   * the wire - a permission click sends exactly
//     {agentId, line: "/permission <value>", submittedAttachments: []} on
//     commands/execute and nothing else: no session/prompt, the composer's
//     draft and images untouched byte for byte, and the success ack writes
//     no projection - the server's permissions / plan frame is the only
//     writer of those states;
//   * the plan toggle - every (active, pending) combination: the two
//     toggleable states send the exact "/plan" and "/plan off" lines, the
//     two pending states send nothing;
//   * the decision order - a missing projection, a value the frozen
//     projection no longer offers, a custom row, an already-current row and
//     a catalog that no longer advertises the command all ask for no change
//     or no capability, with no RPC on the wire;
//   * the answers - a kind:"error" result surfaces its text, an undefined
//     answer is the reference client's unknown-command wording, a malformed
//     result is the malformed-result wording, and a transport failure is
//     the store's visible error;
//   * the full-access preset - recognized and routed to the future gate,
//     never sent directly in C1;
//   * the freeze - a session switch and a reconnect under a parked click
//     stale it: the late answer writes no outcome, no error, no projection
//     and leaves the seat free, and the returned or reconnected session
//     switches fresh;
//   * the seat - the command boundary is one seat, in both directions: a
//     pending preset switch blocks the permission click and the plan toggle,
//     a pending control blocks the switch, and both seats reopen after a
//     settle, a refusal or a stale invalidation;
//   * the projection freeze - the frozen permissions/plan projection is part
//     of the freeze: a removed capability, or a value moved away from the
//     click's own re-emit, under a parked answer stales it - a late success
//     and a late error write nothing - while the server's re-emit of the
//     click's value, the normal projection-before-RPC ordering, keeps the
//     answer live;
//   * the error and outcome ownership - the failure a control lineage wrote
//     is cleared only by a settle of that lineage, a stale completion writes
//     none, an unrelated subsystem's error is left standing, and a session
//     switch or a disconnect retires the outcome and the error with the
//     lineage that wrote them.
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
/// a response can be held back across a session switch or a reconnect -
/// exactly the windows the liveness checks exist for.
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

@main struct SessionControlChecks {
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

    /// The n-th parked commands/execute (1-based), held until the test
    /// resumes it.
    @MainActor
    static func parkedExecute(_ api: FakeAPI, _ n: Int = 1) async -> ParkedCall {
        await spin { api.transport.calls("commands/execute").count >= n }
        return api.transport.calls("commands/execute")[n - 1]
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

    /// The n-th parked agentPresets/select (1-based), held until resumed.
    @MainActor
    static func parkedSwitch(_ api: FakeAPI, _ n: Int = 1) async -> ParkedCall {
        await spin { api.transport.calls("agentPresets/select").count >= n }
        return api.transport.calls("agentPresets/select")[n - 1]
    }

    /// Settle a parked preset switch the way the Host settles it: the
    /// accepted id, the list refresh the accepted switch rides, the model
    /// catalog refresh - and wait for the switch to release its seat.
    @MainActor
    static func settleSwitch(_ store: PocketStore, _ api: FakeAPI, _ accepted: String,
                             sessions: [(id: String, preset: String, blank: Bool)]) async {
        let listBefore = api.transport.calls("session/list").count
        let catBefore = api.transport.calls("session/modelCatalog").count
        let switchCalls = api.transport.calls("agentPresets/select")
        switchCalls[switchCalls.count - 1].respond(.string(accepted))
        await spin { api.transport.calls("session/list").count == listBefore + 1 }
        api.transport.calls("session/list")[listBefore].respond(projectedList(sessions))
        await spin { api.transport.calls("session/modelCatalog").count == catBefore + 1 }
        api.transport.calls("session/modelCatalog")[catBefore].respond(.object(["groups": .array([])]))
        await spin { store.activePresetSwitch == nil && !store.switchingPreset }
    }

    // (1) C1: the permission click's wire shape, its ack and its invariants.
    // The line is the Host's own /permission form, the attachments are
    // exactly the empty array, the draft and the images come back byte for
    // byte, no session/prompt leaves, and the success ack writes no
    // projection: the server's frame is the only writer of the state.
    @MainActor
    static func permissionWireAndInvariants() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA",
             permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]),
             plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        let foldBefore = store.projectionStores["sA"]
        store.draft = "keep me"
        store.images = [img()]
        let task = Task { @MainActor in await store.selectPermission("read-write") }
        let call = await parkedExecute(api)
        assert(call.args == ["agentId": .string("sA"), "line": .string("/permission read-write"), "submittedAttachments": .array([])],
               "the wire is the exact /permission line with no attachments")
        call.respond(execSuccess())
        await task.value
        assert(store.controlOutcome == .sent(line: "/permission read-write"), "the ack settles the sent line")
        assert(store.error == nil, "a success writes no error")
        assert(store.activeControl == nil && store.controls.active == nil, "the seat is released")
        assert(store.draft == "keep me" && store.images.count == 1 && store.images[0].data == Data([1, 2, 3]),
               "the composer's draft and images are untouched")
        assert(store.projectionStores["sA"] == foldBefore, "the success ack wrote no projection")
        assert(api.transport.calls("session/prompt").count == 0, "no session/prompt leaves for a control")
        print("PASS: the permission click sends the exact line and its ack writes nothing")
    }

    // (2) C1: the plan toggle from (active: false, pending: false) - the
    // bare /plan line, nothing more.
    @MainActor
    static func planOffStateSendsBarePlan() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("plan")])
        store.draft = "draft stays"
        store.images = [img()]
        let task = Task { @MainActor in await store.togglePlan() }
        let call = await parkedExecute(api)
        assert(call.args == ["agentId": .string("sA"), "line": .string("/plan"), "submittedAttachments": .array([])],
               "the toggle from off is the bare /plan line")
        call.respond(execSuccess())
        await task.value
        assert(store.controlOutcome == .sent(line: "/plan"), "the ack settles the sent line")
        assert(store.draft == "draft stays" && store.images.count == 1, "the composer is untouched")
        assert(store.projectionStores["sA"]?.plan == PlanProjection(.object(["active": .bool(false), "pending": .bool(false)])),
               "the ack wrote no plan projection")
        print("PASS: plan from off sends the bare /plan line")
    }

    // (3) C1: the plan toggle from (active: true, pending: false) - the
    // /plan off line.
    @MainActor
    static func planOnStateSendsPlanOff() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", plan: planProjection(active: true, pending: false))
        await catalog(store, api, "sA", [descriptor("plan")])
        let task = Task { @MainActor in await store.togglePlan() }
        let call = await parkedExecute(api)
        assert(call.args["line"]?.string == "/plan off", "the toggle from on is /plan off")
        call.respond(execSuccess())
        await task.value
        assert(store.controlOutcome == .sent(line: "/plan off") && store.error == nil)
        print("PASS: plan from on sends /plan off")
    }

    // (4) C1: the plan toggle from (active: false, pending: true) - a
    // transition is already in flight toward the state the click wants, so
    // the click asks for nothing: no RPC on the wire at all.
    @MainActor
    static func planPendingOffSendsNothing() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", plan: planProjection(active: false, pending: true))
        await catalog(store, api, "sA", [descriptor("plan")])
        let task = Task { @MainActor in await store.togglePlan() }
        await task.value
        assert(api.transport.calls("commands/execute").count == 0, "a pending transition owns the toggle")
        assert(store.controlOutcome == .noChange(.planPending), "the click settles no-change")
        assert(store.error == nil && store.activeControl == nil)
        print("PASS: a pending plan transition sends nothing")
    }

    // (5) C1: the plan toggle from (active: true, pending: true) - the
    // pending flag owns the toggle in both directions.
    @MainActor
    static func planPendingOnSendsNothing() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", plan: planProjection(active: true, pending: true))
        await catalog(store, api, "sA", [descriptor("plan")])
        let task = Task { @MainActor in await store.togglePlan() }
        await task.value
        assert(api.transport.calls("commands/execute").count == 0)
        assert(store.controlOutcome == .noChange(.planPending) && store.error == nil)
        print("PASS: a pending plan transition from on sends nothing")
    }

    // (6) C1: a session without the permissions projection has no
    // permission capability: the click asks for the missing capability and
    // sends nothing.
    @MainActor
    static func missingPermissionProjection() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        let task = Task { @MainActor in await store.selectPermission("read-write") }
        await task.value
        assert(api.transport.calls("commands/execute").count == 0)
        assert(store.controlOutcome == .capabilityMissing(.permissionProjection))
        assert(store.error == nil)
        print("PASS: a missing permissions projection is a missing capability")
    }

    // (7) C1: a session without the plan projection has no plan
    // capability: the toggle asks for the missing capability and sends
    // nothing.
    @MainActor
    static func missingPlanProjection() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        let task = Task { @MainActor in await store.togglePlan() }
        await task.value
        assert(api.transport.calls("commands/execute").count == 0)
        assert(store.controlOutcome == .capabilityMissing(.planProjection) && store.error == nil)
        print("PASS: a missing plan projection is a missing capability")
    }

    // (8) C1: custom is the row the projection appends for the display of a
    // policy the catalog no longer names: it is never a switch target, so a
    // click on it is a no-change, not an RPC.
    @MainActor
    static func customPermissionIsNoChange() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "custom", options: ["custom", "read-only"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        let task = Task { @MainActor in await store.selectPermission("custom") }
        await task.value
        assert(api.transport.calls("commands/execute").count == 0, "custom is never sent")
        assert(store.controlOutcome == .noChange(.customPermission) && store.error == nil)
        print("PASS: the custom row is a no-change")
    }

    // (9) C1: a value the frozen projection no longer offers - the preset
    // was removed from the deployment under the click - is a no-change, not
    // a line the Host would refuse.
    @MainActor
    static func removedOptionIsNoChange() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        let task = Task { @MainActor in await store.selectPermission("danger-full-access") }
        await task.value
        assert(api.transport.calls("commands/execute").count == 0)
        assert(store.controlOutcome == .noChange(.removedPermission) && store.error == nil)
        print("PASS: a removed option is a no-change")
    }

    // (10) C1: a value that is already the current value - the switch is a
    // no-op, and the RPC that would re-apply it never leaves.
    @MainActor
    static func currentValueIsNoChange() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        let task = Task { @MainActor in await store.selectPermission("read-only") }
        await task.value
        assert(api.transport.calls("commands/execute").count == 0)
        assert(store.controlOutcome == .noChange(.currentPermission) && store.error == nil)
        print("PASS: the current value is a no-change")
    }

    // (11) C1: a catalog that no longer advertises the permission command -
    // the deployment dropped the preset under the click - is a missing
    // capability, decided after the projection is present.
    @MainActor
    static func missingPermissionCommand() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("plan")])
        let task = Task { @MainActor in await store.selectPermission("read-write") }
        await task.value
        assert(api.transport.calls("commands/execute").count == 0)
        assert(store.controlOutcome == .capabilityMissing(.permissionCommand) && store.error == nil)
        print("PASS: a missing permission command is a missing capability")
    }

    // (12) C1: a catalog that no longer advertises the plan command is the
    // plan capability's absence.
    @MainActor
    static func missingPlanCommand() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission")])
        let task = Task { @MainActor in await store.togglePlan() }
        await task.value
        assert(api.transport.calls("commands/execute").count == 0)
        assert(store.controlOutcome == .capabilityMissing(.planCommand) && store.error == nil)
        print("PASS: a missing plan command is a missing capability")
    }

    // (13) C1: a kind:"error" answer surfaces the Host's own text - the
    // handler's refusal is the visible error, verbatim.
    @MainActor
    static func kindErrorSurfacesText() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        let task = Task { @MainActor in await store.selectPermission("read-write") }
        let call = await parkedExecute(api)
        call.respond(.object(["commandId": .string("c1"), "result": .object(["kind": .string("error"), "text": .string("Unknown permission preset: read-write")])]))
        await task.value
        assert(store.controlOutcome == .failed("Unknown permission preset: read-write"), "the handler's text is the error")
        assert(store.error == "Unknown permission preset: read-write")
        print("PASS: a kind:error answer surfaces its text")
    }

    // (14) C1: an undefined answer - the Host's commands/execute returned
    // nothing at all - is the reference client's unknown-command wording.
    @MainActor
    static func undefinedAnswerIsUnknownCommand() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        let task = Task { @MainActor in await store.selectPermission("read-write") }
        let call = await parkedExecute(api)
        call.respond(.null)
        await task.value
        assert(store.controlOutcome == .failed("Unknown or malformed command: /permission read-write"),
               "the undefined answer is the reference wording")
        assert(store.error == "Unknown or malformed command: /permission read-write")
        print("PASS: an undefined answer is the unknown-command wording")
    }

    // (15) C1: a non-null answer that is neither a success nor an error - a
    // result without a kind - is the malformed-result wording.
    @MainActor
    static func malformedResultIsMalformedWording() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        let task = Task { @MainActor in await store.selectPermission("read-write") }
        let call = await parkedExecute(api)
        call.respond(.object(["commandId": .string("c1")]))
        await task.value
        assert(store.controlOutcome == .failed("Malformed command result: /permission read-write"),
               "the shape without a kind is the malformed wording")
        assert(store.error == "Malformed command result: /permission read-write")
        print("PASS: a malformed answer is the malformed-result wording")
    }

    // (16) C1: a transport failure while the identity is still live - the
    // connection dropped mid-flight - is the store's visible error.
    @MainActor
    static func transportFailureSurfacesError() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        let task = Task { @MainActor in await store.selectPermission("read-write") }
        let call = await parkedExecute(api)
        call.fail(HarnessError(message: "The connection dropped."))
        await task.value
        assert(store.controlOutcome == .failed("The connection dropped."), "the failure is the visible error")
        assert(store.error == "The connection dropped.")
        print("PASS: a transport failure is the store's visible error")
    }

    // (17) C1: the full-access preset is the escalation. C1 recognizes it
    // and routes it to the future full-access gate: no direct
    // commands/execute, no error, the routing outcome the UI renders.
    @MainActor
    static func fullAccessIsRouted() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write", "danger-full-access"]))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        let task = Task { @MainActor in await store.selectPermission("danger-full-access") }
        await task.value
        assert(api.transport.calls("commands/execute").count == 0, "the escalation never leaves directly in C1")
        assert(store.controlOutcome == .routedToFullAccess, "the click routes to the future gate")
        assert(store.error == nil)
        print("PASS: the full-access preset is recognized and routed")
    }

    // (18) C1: a session switch under a parked permission click. The answer
    // of the abandoned click settles stale: no outcome, no error, no
    // projection, the seat released - and the session the click belonged
    // to switches fresh when the user returns to it.
    @MainActor
    static func staleAToBToA() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        store.sessions = [projected("sA"), projected("sB")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]),
             plan: planProjection(active: false, pending: false))
        seed(store, "sB", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]),
             plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        // A baseline click that settles: the outcome it writes is what a
        // stale click must not leak.
        let first = Task { @MainActor in await store.selectPermission("read-write") }
        let firstCall = await parkedExecute(api)
        firstCall.respond(execSuccess())
        await first.value
        assert(store.controlOutcome == .sent(line: "/permission read-write"))
        // The abandoned click: parked, then the selection moves away.
        let second = Task { @MainActor in await store.selectPermission("read-write") }
        await spin { api.transport.calls("commands/execute").count == 2 }
        await store.select("sB")
        assert(store.activeControl == nil, "leaving the session dropped the click's seat")
        api.transport.calls("commands/execute")[1].respond(execSuccess())
        await second.value
        assert(store.error == nil, "the abandoned click wrote no error")
        assert(store.controlOutcome == nil, "the abandoned click wrote no outcome over the newer selection")
        assert(store.projectionStores["sA"]?.permissions?.currentValue == "read-only",
               "the abandoned click wrote no projection")
        // A -> B -> A: the returned session switches fresh on the free seat.
        await store.select("sA")
        let third = Task { @MainActor in await store.selectPermission("read-write") }
        await spin { api.transport.calls("commands/execute").count == 3 }
        api.transport.calls("commands/execute")[2].respond(execSuccess())
        await third.value
        assert(store.controlOutcome == .sent(line: "/permission read-write") && store.error == nil,
               "the returned session switches fresh")
        print("PASS: A -> B -> A stales the abandoned click, and the returned session switches fresh")
    }

    // (19) C1: a reconnect under a parked permission click. The dead
    // connection's answer settles stale and writes nothing; the new
    // connection rewarms its own catalog and its click settles on its own
    // identity.
    @MainActor
    static func reconnectStalesOldAnswer() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]),
             plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        let task = Task { @MainActor in await store.selectPermission("read-write") }
        await spin { api.transport.calls("commands/execute").count == 1 }
        // The connection drops under the parked click: the seat is dropped
        // with it, and the catalog of the dead connection goes with it.
        store.disconnect()
        let api2 = FakeAPI()
        store.api = api2
        store.connected = true
        // The dead connection's answer arrives: it must write nothing.
        api.transport.calls("commands/execute")[0].respond(execSuccess())
        await task.value
        assert(store.error == nil, "the dead connection's answer wrote no error")
        assert(store.controlOutcome == nil, "the dead connection's answer wrote no outcome")
        assert(store.activeControl == nil && store.controls.active == nil, "the seat is free for the new connection")
        // The new connection rewars its own catalog and switches fresh.
        await catalog(store, api2, "sA", [descriptor("permission"), descriptor("plan")])
        let again = Task { @MainActor in await store.selectPermission("read-write") }
        await spin { api2.transport.calls("commands/execute").count == 1 }
        api2.transport.calls("commands/execute")[0].respond(execSuccess())
        await again.value
        assert(store.controlOutcome == .sent(line: "/permission read-write") && store.error == nil,
               "the new connection's click settles on its own identity")
        print("PASS: a reconnect stales the dead connection's answer, and the new one switches fresh")
    }


    // (20) C1: the command boundary is one seat, from the switch's side. A
    // pending preset switch blocks the permission click and the plan toggle
    // before any commands/execute leaves - the second seat is refused, not
    // superseded - and the seat reopens the moment the switch settles.
    @MainActor
    static func pendingSwitchOwnsTheControlSeat() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        store.sessions = [projected("sA"), projected("sB")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]),
             plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        let sw = Task { @MainActor in await store.selectPreset("p2") }
        let switchCall = await parkedSwitch(api)
        assert(switchCall.args == ["agentId": .string("sA"), "agentPreset": .string("p2")], "the switch is parked on its own line")
        // The control clicks are refused before the wire while it is pending.
        await store.selectPermission("read-write")
        await store.togglePlan()
        assert(api.transport.calls("commands/execute").count == 0, "a pending switch blocks both controls before the wire")
        assert(store.activeControl == nil && store.controlOutcome == nil && store.error == nil, "the refusals are silent")
        // The switch settles: the seat reopens, and the same click dispatches.
        await settleSwitch(store, api, "p2", sessions: [("sA", "p2", true), ("sB", "", true)])
        await sw.value
        let click = Task { @MainActor in await store.selectPermission("read-write") }
        let call = await parkedExecute(api, 1)
        assert(call.args == ["agentId": .string("sA"), "line": .string("/permission read-write"), "submittedAttachments": .array([])])
        call.respond(execSuccess())
        await click.value
        assert(store.controlOutcome == .sent(line: "/permission read-write") && store.error == nil, "the reopened seat dispatches fresh")
        print("PASS: a pending switch blocks the controls, and the seat reopens when it settles")
    }

    // (21) C1: the command boundary is one seat, from the control's side. A
    // pending permission click and a pending plan toggle each block the
    // preset switch before any agentPresets/select leaves, and the seat
    // reopens when the control settles.
    @MainActor
    static func pendingControlOwnsTheSwitchSeat() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        store.sessions = [projected("sA"), projected("sB")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]),
             plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        // A pending permission click blocks the switch before the wire.
        let click = Task { @MainActor in await store.selectPermission("read-write") }
        await spin { api.transport.calls("commands/execute").count == 1 }
        await store.selectPreset("p2")
        assert(api.transport.calls("agentPresets/select").count == 0 && store.activePresetSwitch == nil && !store.switchingPreset,
               "a pending permission click blocks the switch before the wire")
        await parkedExecute(api, 1).respond(execSuccess())
        await click.value
        assert(store.controlOutcome == .sent(line: "/permission read-write"))
        // The seat reopens for the switch, which then settles.
        let sw = Task { @MainActor in await store.selectPreset("p2") }
        await spin { api.transport.calls("agentPresets/select").count == 1 }
        await settleSwitch(store, api, "p2", sessions: [("sA", "p2", true), ("sB", "", true)])
        await sw.value
        // A pending plan toggle blocks the switch before the wire too.
        let toggle = Task { @MainActor in await store.togglePlan() }
        await spin { api.transport.calls("commands/execute").count == 2 }
        await store.selectPreset("p3")
        assert(api.transport.calls("agentPresets/select").count == 1, "a pending plan toggle blocks the switch before the wire")
        await parkedExecute(api, 2).respond(execSuccess())
        await toggle.value
        assert(store.controlOutcome == .sent(line: "/plan") && store.error == nil, "the plan toggle settles the line it froze")
        print("PASS: a pending permission or plan control blocks the switch, and the seat reopens")
    }

    // (22) C1: a stale invalidation - the session switch under a parked
    // control - reopens both seats: the switch the abandoned click could no
    // longer block, and the control the switch's answer no longer stales.
    @MainActor
    static func staleInvalidationReopensBothSeats() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        store.sessions = [projected("sA"), projected("sB")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        seed(store, "sB", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        let parked = Task { @MainActor in await store.selectPermission("read-write") }
        await spin { api.transport.calls("commands/execute").count == 1 }
        // The selection moves away: the click's seat is dropped with it.
        await store.select("sB")
        assert(store.activeControl == nil, "leaving the session dropped the click's seat")
        // The switch on the new session proceeds: the control no longer blocks it.
        let sw = Task { @MainActor in await store.selectPreset("p2") }
        await spin { api.transport.calls("agentPresets/select").count == 1 }
        // The abandoned click's answer arrives: it writes nothing, and it
        // does not touch the switch that now owns the seat.
        api.transport.calls("commands/execute")[0].respond(execSuccess())
        await parked.value
        assert(store.controlOutcome == nil && store.error == nil, "the abandoned answer wrote nothing")
        assert(store.activePresetSwitch != nil, "the switch still owns its own seat")
        await settleSwitch(store, api, "p2", sessions: [("sA", "", true), ("sB", "p2", true)])
        await sw.value
        assert(store.activePresetSwitch == nil && store.activeControl == nil, "both seats are free again")
        // The control seat reopens too: the new session switches fresh.
        await catalog(store, api, "sB", [descriptor("permission")])
        let fresh = Task { @MainActor in await store.selectPermission("read-write") }
        let freshCall = await parkedExecute(api, 2)
        assert(freshCall.args["line"] == .string("/permission read-write"))
        freshCall.respond(execSuccess())
        await fresh.value
        assert(store.controlOutcome == .sent(line: "/permission read-write") && store.error == nil, "the new session switches fresh")
        print("PASS: a stale invalidation reopens the control seat and the switch seat")
    }

    // (23) C1: the frozen projection is part of the freeze. A permissions
    // projection that loses the capability - or moves to a value the click
    // did not ask for - under a parked permission click stales the answer:
    // a late success and a late error both write no outcome and no error.
    @MainActor
    static func permissionProjectionLiveness() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        // The capability disappears under the parked click: a fresh fold
        // without the permissions key, exactly the removal the Host serves.
        let first = Task { @MainActor in await store.selectPermission("read-write") }
        let firstCall = await parkedExecute(api, 1)
        store.projectionStores["sA"] = SessionProjectionStore()
        firstCall.respond(execSuccess())
        await first.value
        assert(store.controlOutcome == nil && store.error == nil, "a late success over a removed capability writes nothing")
        assert(store.activeControl == nil, "the seat is released")
        // A fresh fold: the same window applies to a value the click did not
        // ask for, with the late error instead of the late success.
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        let second = Task { @MainActor in await store.selectPermission("read-write") }
        let secondCall = await parkedExecute(api, 2)
        store.projectionStores["sA"]?.apply(key: ProjectionKey.permissions,
                                           value: permProjection(currentValue: "danger-full-access", options: ["read-only", "read-write"]), seq: 9)
        secondCall.respond(.object(["commandId": .string("c2"), "result": .object(["kind": .string("error"), "text": .string("boom")])]))
        await second.value
        assert(store.controlOutcome == nil && store.error == nil, "a late error over a moved projection writes nothing")
        print("PASS: a removed or moved permissions projection stales the parked answer")
    }

    // (24) C1: the same liveness on the plan projection. A parked toggle is
    // staled by the plan capability disappearing, and by a transition in
    // flight in the direction the toggle did not ask for.
    @MainActor
    static func planProjectionLiveness() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("plan")])
        // The plan capability disappears under the parked toggle.
        let first = Task { @MainActor in await store.togglePlan() }
        let firstCall = await parkedExecute(api, 1)
        store.projectionStores["sA"] = SessionProjectionStore()
        firstCall.respond(execSuccess())
        await first.value
        assert(store.controlOutcome == nil && store.error == nil, "a late success over a removed plan projection writes nothing")
        // A fresh fold: a transition in flight in the direction the toggle
        // did not ask for moves the mode without this click.
        seed(store, "sA", plan: planProjection(active: false, pending: false))
        let second = Task { @MainActor in await store.togglePlan() }
        let secondCall = await parkedExecute(api, 2)
        // The toggle froze (false, false) and asked for the mode on. The
        // live fold is (true, true): the mode already on, a transition in
        // flight back to off - without this click.
        store.projectionStores["sA"]?.apply(key: ProjectionKey.plan, value: planProjection(active: true, pending: true), seq: 9)
        secondCall.respond(.object(["commandId": .string("c2"), "result": .object(["kind": .string("error"), "text": .string("boom")])]))
        await second.value
        assert(store.controlOutcome == nil && store.error == nil, "a late error over a moved plan projection writes nothing")
        print("PASS: a removed or moved plan projection stales the parked toggle")
    }

    // (25) C1: the normal server ordering is not a move under the click. The
    // Host applies the switch and republishes the projection before the ack
    // arrives - the projection-before-RPC ordering - and that re-emit keeps
    // the parked answer live: the outcome still settles as the sent line,
    // with no error.
    @MainActor
    static func normalReprojectionKeepsTheSuccess() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        store.sessions = [projected("sA")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]),
             plan: planProjection(active: false, pending: false))
        await catalog(store, api, "sA", [descriptor("permission"), descriptor("plan")])
        // The permission switch: the server republishes the new value before
        // the ack, exactly as the Host does.
        let first = Task { @MainActor in await store.selectPermission("read-write") }
        let firstCall = await parkedExecute(api, 1)
        store.projectionStores["sA"]?.apply(key: ProjectionKey.permissions,
                                           value: permProjection(currentValue: "read-write", options: ["read-only", "read-write"]), seq: 9)
        firstCall.respond(execSuccess())
        await first.value
        assert(store.controlOutcome == .sent(line: "/permission read-write") && store.error == nil,
               "the server's re-emit of the click's own value keeps the answer live")
        // The plan toggle: the in-flight transition the toggle itself drives
        // is the re-emit, not a move.
        let second = Task { @MainActor in await store.togglePlan() }
        let secondCall = await parkedExecute(api, 2)
        store.projectionStores["sA"]?.apply(key: ProjectionKey.plan, value: planProjection(active: false, pending: true), seq: 10)
        secondCall.respond(execSuccess())
        await second.value
        assert(store.controlOutcome == .sent(line: "/plan") && store.error == nil,
               "the toggle's own transition in flight keeps the answer live")
        print("PASS: the server's projection-before-RPC ordering keeps the answer live")
    }

    // (26) C1: the error the control lineage wrote is owned by the lineage.
    // A failed attempt is the visible error; a settled retry of the same
    // lineage clears exactly that message; and a stale completion of a
    // failed attempt writes no error over the session that replaced it.
    @MainActor
    static func controlErrorLifecycle() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        store.sessions = [projected("sA"), projected("sB")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        seed(store, "sB", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        // A failed attempt is the visible error...
        let first = Task { @MainActor in await store.selectPermission("read-write") }
        let firstCall = await parkedExecute(api, 1)
        firstCall.respond(.object(["commandId": .string("c1"), "result": .object(["kind": .string("error"), "text": .string("boom")])]))
        await first.value
        assert(store.controlOutcome == .failed("boom") && store.error == "boom", "the failure is the visible error")
        // ...and a settled retry of the same lineage clears exactly that message.
        let second = Task { @MainActor in await store.selectPermission("read-write") }
        let secondCall = await parkedExecute(api, 2)
        secondCall.respond(execSuccess())
        await second.value
        assert(store.controlOutcome == .sent(line: "/permission read-write") && store.error == nil,
               "the settled retry clears the error the lineage wrote")
        // A stale completion of a failed attempt writes no error over the
        // session that replaced it.
        let third = Task { @MainActor in await store.selectPermission("read-write") }
        let thirdCall = await parkedExecute(api, 3)
        await store.select("sB")
        thirdCall.respond(.object(["commandId": .string("c3"), "result": .object(["kind": .string("error"), "text": .string("boom")])]))
        await third.value
        assert(store.controlOutcome == nil && store.error == nil, "a stale failed completion writes nothing")
        print("PASS: the control error is owned by the lineage, and a stale failure writes nothing")
    }

    // (27) C1: ownership is by the exact message the lineage wrote. An error
    // another subsystem published over the control's own is not the
    // control's to clear: a settled control leaves it standing.
    @MainActor
    static func successKeepsAnUnrelatedError() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        store.sessions = [projected("sA"), projected("sB")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        // The control fails and owns its error...
        let first = Task { @MainActor in await store.selectPermission("read-write") }
        let firstCall = await parkedExecute(api, 1)
        firstCall.fail(HarnessError(message: "The connection dropped."))
        await first.value
        assert(store.controlOutcome == .failed("The connection dropped.") && store.error == "The connection dropped.")
        // ...and the switch, which the control no longer blocks, fails over
        // it with its own wording.
        let sw = Task { @MainActor in await store.selectPreset("p2") }
        let switchCall = await parkedSwitch(api, 1)
        switchCall.fail(HarnessError(message: "The preset switch was refused."))
        await sw.value
        assert(store.error == "The preset switch was refused.", "the switch's refusal is the visible error")
        // The control's settled success clears its own message - and only its
        // own: the switch's refusal is not the control's to erase.
        let second = Task { @MainActor in await store.selectPermission("read-write") }
        let secondCall = await parkedExecute(api, 2)
        secondCall.respond(execSuccess())
        await second.value
        assert(store.controlOutcome == .sent(line: "/permission read-write"), "the retry settles")
        assert(store.error == "The preset switch was refused.", "the unrelated error is left standing")
        print("PASS: a settled control clears its own error, not another subsystem's")
    }

    // (28) C1: the outcome and the error the control settled belong to the
    // session and the connection they rode. A switch and a disconnect retire
    // them: the session that replaces A never sees A's settled outcome,
    // returning to A finds the control state clean, not resurrected, and the
    // dead connection's late answer writes nothing.
    @MainActor
    static func settledStateIsOwnedByItsSession() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        store.sessions = [projected("sA"), projected("sB")]
        await store.select("sA")
        seed(store, "sA", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        seed(store, "sB", permissions: permProjection(currentValue: "read-only", options: ["read-only", "read-write"]))
        await catalog(store, api, "sA", [descriptor("permission")])
        let first = Task { @MainActor in await store.selectPermission("read-write") }
        let firstCall = await parkedExecute(api, 1)
        firstCall.respond(execSuccess())
        await first.value
        assert(store.controlOutcome == .sent(line: "/permission read-write"))
        // The switch retires A's settled state...
        await store.select("sB")
        assert(store.controlOutcome == nil && store.error == nil, "A's settled outcome is not presented as B's")
        // ...and returning to A finds it clean, not resurrected.
        await store.select("sA")
        assert(store.controlOutcome == nil, "the outcome is not resurrected on return")
        // A fresh click on the returned session parks a new answer...
        let second = Task { @MainActor in await store.selectPermission("read-write") }
        let secondCall = await parkedExecute(api, 2)
        // ...and a disconnect under it retires the control state: the dead
        // connection's answer writes nothing.
        store.disconnect()
        let api2 = FakeAPI()
        store.api = api2
        store.connected = true
        secondCall.respond(execSuccess())
        await second.value
        assert(store.controlOutcome == nil && store.error == nil, "the dead connection's answer writes nothing")
        print("PASS: a settled outcome and error are owned by their session and connection")
    }

    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do {
            try await permissionWireAndInvariants()
            try await planOffStateSendsBarePlan()
            try await planOnStateSendsPlanOff()
            try await planPendingOffSendsNothing()
            try await planPendingOnSendsNothing()
            try await missingPermissionProjection()
            try await missingPlanProjection()
            try await customPermissionIsNoChange()
            try await removedOptionIsNoChange()
            try await currentValueIsNoChange()
            try await missingPermissionCommand()
            try await missingPlanCommand()
            try await kindErrorSurfacesText()
            try await undefinedAnswerIsUnknownCommand()
            try await malformedResultIsMalformedWording()
            try await transportFailureSurfacesError()
            try await fullAccessIsRouted()
            try await staleAToBToA()
            try await reconnectStalesOldAnswer()
            try await pendingSwitchOwnsTheControlSeat()
            try await pendingControlOwnsTheSwitchSeat()
            try await staleInvalidationReopensBothSeats()
            try await permissionProjectionLiveness()
            try await planProjectionLiveness()
            try await normalReprojectionKeepsTheSuccess()
            try await controlErrorLifecycle()
            try await successKeepsAnUnrelatedError()
            try await settledStateIsOwnedByItsSession()
            print("PASS: the permission and plan intents freeze, decide and dispatch exactly")
            exit(0)
        }
        catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
