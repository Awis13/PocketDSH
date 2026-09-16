import Foundation

// PARITY-2B B2: the preset roster, the session/create request builder, and
// the operation-owned Create outcome - driven through the production
// PocketStore.create, the production CreateSheetOwnership seat and the same
// callback path NewTaskView uses: await store.create, then the returned
// CreateResult decides the sheet.
//
// What the checks close:
//
//   * the roster - empty, missing, broken, removed and custom rows served by
//     agentPresets/list parse into the picker's options; broken and removed
//     rows stay shown with their reason and unselectable; a row without an id
//     is not a row; a failed fetch and a fetch of a rotated generation write
//     their own states; overlapping pulls on the same connection keep the
//     latest pull authoritative - a superseded pull, answered later or
//     failing later, overwrites nothing;
//   * the picker policy - the host default is the first option and never
//     mutates; a staged id the loaded roster no longer advertises stays
//     shown verbatim with its removal reason, unselectable; while the roster
//     is not loaded an unknown staged id stays selectable, verbatim; a known
//     staged id is not duplicated;
//   * the wire - the default omits agentPreset from the request entirely, an
//     explicit choice sends the exact advertised id, the workspace follows the
//     same omission rule, and the production create puts that exact request
//     on the wire;
//   * ownership - a failed create with a previously selected session is the
//     outcome of this create only: no selection move, no list refresh, no
//     focus, and the sheet stays open; closing the sheet - Cancel or a
//     swipe, the production seam NewTaskView uses - retires the in-flight
//     create, and a reopened sheet that does not press Create gets nothing
//     from its parked answer; A -> B -> A leaves the selection and the focus
//     alone in both answer orders; a reconnect stales the answer of the dead
//     connection;
//   * session/workspace-attach-failed - the list is refreshed on the same
//     live connection and the session becomes visible; it is never a success,
//     never retried, never selected, and it closes no sheet; a switch while
//     that refresh is parked stales the create - no error, no list, no
//     focus;
//   * the create's own select - its follow parks on a slow socket and its
//     self-select keeps the sheet's seat: a switch during the follow stales
//     the create - no .created, no dismiss, no focus, no selection theft; an
//     A -> B -> A back onto the create's session cannot revive it; a sheet
//     close during the follow stales it; a newer create keeps its outcome,
//     focus and sheet over the old create's late follow - while a legitimate
//     select still settles .created;
//   * the native path - create stays local: no session/create on the wire;
//     the create settles .created only on a confirmed open of its own
//     session, and only then does the composer focus land; a rejected open
//     settles .failed with the visible error, the prior selection restored,
//     no focus, no auto-retry, no sheet close; a sheet close or a supersede
//     during a parked open stales the old create, and its late failure
//     writes no error over the newer sheet - the newer create keeps its
//     outcome, focus and selection.
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
/// a response can be held back across a supersede, a session switch or a
/// reconnect - exactly the windows the liveness checks exist for.
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

/// One parked stream socket: every frame the carrier tries to send parks
/// until the test releases it, so a conversation follow can be held open
/// across a session switch or a reconnect - the interleaving a slow socket
/// would produce on a real carrier.
@MainActor
final class ParkedTransport: RemoteStreamTransport {
    private(set) var sent: [JSON] = []
    private var continuations: [CheckedContinuation<Void, Error>?] = []
    func sendFrame(_ frame: JSON) async throws {
        let index = sent.count
        sent.append(frame)
        continuations.append(nil)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuations[index] = continuation
        }
    }
    func ping() async throws {}
    func release(_ index: Int) {
        guard continuations.indices.contains(index) else { return }
        if let continuation = continuations[index] {
            continuations[index] = nil
            continuation.resume()
        }
    }
}

@main struct PresetSelectionChecks {
    /// One preset row, shaped exactly as agentPresets/list serves it.
    @MainActor
    static func presetRow(id: String, name: String, trust: String = "system", isDefault: Bool = false, broken: String? = nil) -> JSON {
        var row: [String: JSON] = ["id": .string(id), "name": .string(name), "trust": .string(trust), "isDefault": .bool(isDefault)]
        if let broken { row["broken"] = .string(broken) }
        return .object(row)
    }

    /// A session/create response; agentPreset is omitted exactly as the Host
    /// omits it for an unconfigured preset.
    @MainActor
    static func created(_ sessionID: String, preset: String?) -> JSON {
        var value: [String: JSON] = ["sessionId": .string(sessionID)]
        if let preset { value["agentPreset"] = .string(preset) }
        return .object(value)
    }

    /// A session/list response with exactly these ids.
    @MainActor
    static func list(_ ids: [String]) -> JSON {
        .object(["items": .array(ids.map { .object(["sessionId": .string($0), "cwd": .string("/w"), "updatedAt": .number(1), "running": .bool(false)]) })])
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
        store.sessions = sessions.map { HarnessSession(raw: .object(["sessionId": .string($0), "cwd": .string("/w"), "updatedAt": .number(1), "running": .bool(false)])) }
    }

    /// Drive one production refreshPresetRoster against the parked transport:
    /// the answer is held until the test resumes it.
    @MainActor
    static func fetchRoster(_ store: PocketStore, _ api: FakeAPI, respond: (ParkedCall) -> Void) async {
        let task = Task { @MainActor in await store.refreshPresetRoster() }
        let before = api.transport.calls("agentPresets/list").count
        await spin { api.transport.calls("agentPresets/list").count == before + 1 }
        assert(store.presetRoster == .loading, "the picker shows the load until the answer lands")
        respond(api.transport.calls("agentPresets/list")[before])
        await task.value
    }

    /// A native open frame held until the test releases it: the production
    /// select parks on its own seam, exactly where the live socket would.
    @MainActor
    final class ParkedNativeOpen {
        private(set) var sent: [NativeCommand] = []
        private var continuations: [CheckedContinuation<Void, Error>?] = []
        func send(_ command: NativeCommand) async throws {
            let index = sent.count
            sent.append(command)
            continuations.append(nil)
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                continuations[index] = continuation
            }
        }
        func release(_ i: Int) {
            guard continuations.indices.contains(i) else { return }
            if let continuation = continuations[i] {
                continuations[i] = nil
                continuation.resume()
            }
        }
        func fail(_ i: Int, _ error: Error) {
            guard continuations.indices.contains(i) else { return }
            if let continuation = continuations[i] {
                continuations[i] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// The store's transport in the production create checks: the production
    /// wiring stays live end to end - the shell's `externalSend` bridge, its
    /// Task and the error surfacing are all the real PocketStore code - but
    /// the socket write is a recorded no-op success, the way a connected
    /// host acknowledges a resize. In these scenarios the create's own open
    /// frame is owned by the seam, so the connection carries only the
    /// seeded shell's unrelated traffic (a resize after the seed); left on
    /// a socketless NativeChatConnection that traffic throws from an async
    /// Task and can write `error` under any assertion, racing the create
    /// outcomes. The create's own failure path - the open catch publishing
    /// while the seat still holds - bypasses the connection and is asserted
    /// unchanged.
    @MainActor
    final class RecordingNativeConnection: NativeChatConnection {
        private(set) var sent: [NativeCommand] = []
        override func send(_ command: NativeCommand) async throws {
            sent.append(command)
        }
    }

    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do {
            try await createRequestWireShape()
            try await pickerOptionsPolicy()
            try await rosterShapes()
            try await prodRosterPullsLatestWins()
            try await prodFailedCreateKeepsOldSelection()
            try await prodSheetCloseStalesInFlightCreate()
            try await prodOverlapBothOrders()
            try await prodAToBToADoesNotSteal()
            try await prodReconnectStalesOldAnswer()
            try await prodAttachFailedRefreshesOnly()
            try await prodAttachFailedParkedRefreshStalesOnSwitch()
            try await prodFollowParkSwitchStalesCreate()
            try await prodSheetCloseDuringFollowStalesCreate()
            try await prodFollowParkABACannotReviveCreate()
            try await prodFollowParkNewerCreateKeepsOutcome()
            try await prodNativeCreateOpenFailure()
            try await prodNativeCreateOpenSuccess()
            try await prodNativeCreateParkedOpen()
            try await prodNativeCreateEarlyHostReply()
            try await prodNativeCreateHostRejection()
            try await prodNativeCreateHostAckAfterSend()
            try await prodNativeCreateEarlyReplayOverflow()
            try await prodNativeCreateStaleCloseDuringAck()
            try await prodNativeCreateParkedAckThenSheetClose()
            try await prodNativeCreateConnectionLossDuringAck()
            try newTaskSheetRetirement()
            print("PASS: the preset roster loads, the create request omits the default, and each create owns its outcome")
            exit(0)
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    // (1) The wire shape of the request builder: the default sends only the
    // session identity; an explicit choice and workspace travel verbatim;
    // empty values are omitted, never sent as empty strings.
    @MainActor
    static func createRequestWireShape() async throws {
        let plain = PresetSelection.createRequest(sessionID: "s1", workspaceID: nil, agentPreset: nil)
        assert(plain["sessionId"]?.string == "s1" && plain["workspaceId"] == nil && plain["agentPreset"] == nil,
               "the default create sends only the session identity")
        let explicit = PresetSelection.createRequest(sessionID: "s1", workspaceID: "w1", agentPreset: "custom-preset")
        assert(explicit["sessionId"]?.string == "s1" && explicit["workspaceId"]?.string == "w1" && explicit["agentPreset"]?.string == "custom-preset",
               "the explicit workspace and preset travel verbatim")
        let empty = PresetSelection.createRequest(sessionID: "s1", workspaceID: "", agentPreset: "")
        assert(empty["workspaceId"] == nil && empty["agentPreset"] == nil,
               "an empty workspace or preset omits its key, it is not sent empty")
        print("PASS: the create request omits the default and sends the explicit choice verbatim")
    }

    // (2) The picker policy: the host default is always the first option; the
    // loaded roster follows in Host order with broken rows unselectable and
    // reasoned; a staged id the loaded roster no longer advertises is a
    // removed selection - verbatim, reasoned, unselectable; while the roster
    // is not loaded an unknown staged id stays selectable, verbatim; a known
    // staged id is not duplicated.
    @MainActor
    static func pickerOptionsPolicy() async throws {
        let bare = PresetSelection.pickerOptions(roster: .missing, staged: nil)
        assert(bare.count == 1 && bare[0] == PresetPickerOption.default && bare[0].presetID == nil && bare[0].selectable,
               "the host default is the first option and always selectable")
        assert(PresetSelection.pickerOptions(roster: .loading, staged: nil) == [PresetPickerOption.default],
               "a roster that is loading offers only the default")
        assert(PresetSelection.pickerOptions(roster: .failed("refused"), staged: nil) == [PresetPickerOption.default],
               "a failed roster offers only the default, not its failure")
        let roster: AgentPresetRosterState = .loaded(rows: [
            AgentPresetRow(id: "p-a", trust: "system", isDefault: true, name: "A"),
            AgentPresetRow(id: "p-b", trust: "user", isDefault: false, name: "B", broken: "cannot compose a session")
        ], authorable: true)
        let options = PresetSelection.pickerOptions(roster: roster, staged: nil)
        assert(options.count == 3 && options[0] == PresetPickerOption.default, "the default leads, the roster follows")
        assert(options[1].presetID == "p-a" && options[1].title == "A" && options[1].selectable && options[1].isDefault,
               "the advertised default row keeps its badge and stays selectable")
        assert(options[2].presetID == "p-b" && !options[2].selectable && options[2].reason == "cannot compose a session",
               "the broken row stays shown, with its reason, unselectable")
        let staged = PresetSelection.pickerOptions(roster: .missing, staged: "p-gone")
        assert(staged.count == 2 && staged[1].presetID == "p-gone" && staged[1].title == "p-gone" && staged[1].selectable,
               "an unknown staged id with an unloaded roster stays selectable, shown verbatim")
        // The same staged id against a loaded roster is a removed selection:
        // it stays shown, verbatim, with its reason, and it is unselectable.
        let removed = PresetSelection.pickerOptions(roster: roster, staged: "p-gone")
        assert(removed.count == 4 && removed[3].presetID == "p-gone" && removed[3].title == "p-gone",
               "the removed selection stays shown, verbatim")
        assert(!removed[3].selectable && removed[3].reason == "No longer offered by the server",
               "the removed selection is unselectable, with its removal reason")
        let known = PresetSelection.pickerOptions(roster: roster, staged: "p-a")
        assert(known.count == 3 && known.filter { $0.presetID == "p-a" }.count == 1, "a known staged id is not duplicated")
        print("PASS: the picker keeps the default first, the reasons visible, removed ids reasoned and unselectable")
    }

    // (3) The roster through the production refreshPresetRoster: empty,
    // missing, broken, removed, custom and id-less shapes; a failed fetch;
    // and a fetch whose generation rotated while it was in flight.
    @MainActor
    static func rosterShapes() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        // An empty roster: no advertised presets, the picker offers only the
        // default, and the state says the list was served.
        await fetchRoster(store, api) { $0.respond(.object(["presets": .array([]), "authorable": .bool(true)])) }
        assert(store.presetRoster == .loaded(rows: [], authorable: true), "an empty roster loads as empty, not as missing")
        // A list that answers without a presets array: no advertised presets.
        await fetchRoster(store, api) { $0.respond(.object([:])) }
        assert(store.presetRoster == .missing, "a list without a presets array is missing, not a crash")
        // The full shape: broken and removed rows stay with their reason, the
        // custom row keeps its trust, and a row without an id is not a row.
        let roster: JSON = .object([
            "presets": .array([
                presetRow(id: "p-broken", name: "Broken one", broken: "its model catalog is gone"),
                presetRow(id: "p-removed", name: "Removed one", broken: "the preset was removed from the Host"),
                presetRow(id: "p-custom", name: "My preset", trust: "user"),
                .object(["name": .string("no id"), "trust": .string("system")])
            ]),
            "authorable": .bool(true)
        ])
        await fetchRoster(store, api) { $0.respond(roster) }
        if case .loaded(let rows, let authorable) = store.presetRoster {
            assert(authorable, "the authorable flag survives the fetch")
            assert(rows.count == 3, "the row without an id is not a row")
            assert(rows[0].id == "p-broken" && rows[0].broken == "its model catalog is gone" && !rows[0].selectable && rows[0].title == "Broken one",
                   "the broken row keeps its reason and stays unselectable")
            assert(rows[1].id == "p-removed" && !rows[1].selectable && rows[1].title == "Removed one",
                   "the removed row stays shown, with its reason, unselectable")
            assert(rows[2].id == "p-custom" && rows[2].trust == "user" && rows[2].selectable && rows[2].title == "My preset",
                   "the custom row keeps its trust and stays selectable")
        } else {
            assert(false, "the served roster must load")
        }
        // A failed fetch: the picker shows the failure, not a stale roster.
        await fetchRoster(store, api) { $0.fail(HarnessError(message: "the roster endpoint refused")) }
        assert(store.presetRoster == .failed("the roster endpoint refused"), "a failed fetch reports its failure")
        // A fetch whose connection rotated in flight writes nothing: the
        // disconnect's reset stays, the late answer lands nowhere.
        let task = Task { @MainActor in await store.refreshPresetRoster() }
        let before = api.transport.calls("agentPresets/list").count
        await spin { api.transport.calls("agentPresets/list").count == before + 1 }
        store.disconnect()
        api.transport.calls("agentPresets/list")[before].respond(.object(["presets": .array([presetRow(id: "p-late", name: "Late one")]), "authorable": .bool(true)]))
        await task.value
        assert(store.presetRoster == .missing, "a rotated generation's fetch writes nothing over the disconnect's reset")
        print("PASS: the roster loads every served shape, and a dead connection's fetch writes nothing")
    }

    // (4) The roster's pull ownership: a connect and a picker open can issue
    // two overlapping agentPresets/list pulls on the same connection. The
    // latest pull is authoritative in any answer order: a superseded pull,
    // answered later or failing later, overwrites nothing.
    @MainActor
    static func prodRosterPullsLatestWins() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        let older: JSON = .object(["presets": .array([presetRow(id: "p-old", name: "Old one")]), "authorable": .bool(true)])
        let newer: JSON = .object(["presets": .array([presetRow(id: "p-new", name: "New one")]), "authorable": .bool(false)])
        // The connect issues the first pull, the picker's open the second,
        // before either answers.
        let a = Task { @MainActor in await store.refreshPresetRoster() }
        await spin { api.transport.calls("agentPresets/list").count == 1 }
        let b = Task { @MainActor in await store.refreshPresetRoster() }
        await spin { api.transport.calls("agentPresets/list").count == 2 }
        // The newer pull answers first...
        api.transport.calls("agentPresets/list")[1].respond(newer)
        await b.value
        // ...and the older pull answers last: it lands nowhere.
        api.transport.calls("agentPresets/list")[0].respond(older)
        await a.value
        if case .loaded(let rows, let authorable) = store.presetRoster {
            assert(rows.count == 1 && rows[0].id == "p-new" && !authorable, "the latest pull's roster stays, the older answer lands nowhere")
        } else {
            assert(false, "the latest pull's roster must load")
        }
        // A superseded pull that fails after the newer one succeeded writes
        // no failure over it either.
        let c = Task { @MainActor in await store.refreshPresetRoster() }
        await spin { api.transport.calls("agentPresets/list").count == 3 }
        let d = Task { @MainActor in await store.refreshPresetRoster() }
        await spin { api.transport.calls("agentPresets/list").count == 4 }
        api.transport.calls("agentPresets/list")[3].respond(.object(["presets": .array([presetRow(id: "p-latest", name: "Latest one")]), "authorable": .bool(true)]))
        await d.value
        api.transport.calls("agentPresets/list")[2].fail(HarnessError(message: "the roster endpoint refused"))
        await c.value
        if case .loaded(let rows, _) = store.presetRoster {
            assert(rows.count == 1 && rows[0].id == "p-latest", "a superseded pull's failure overwrites nothing")
        } else {
            assert(false, "the latest pull's roster must survive the older failure")
        }
        print("PASS: the latest roster pull stays authoritative in any answer order")
    }

    // (5) Production: a failed create with a previously selected session is
    // the outcome of this create only. The old view closed its sheet on
    // selectedID != nil - a failure with a selected session looked like a
    // success. The owned outcome does not.
    @MainActor
    static func prodFailedCreateKeepsOldSelection() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        await store.select("sA")
        let task = Task { @MainActor in await store.create(workspaceID: nil, presetID: nil) }
        await spin { api.transport.calls("session/create").count == 1 }
        // The wire shape of the production request: the default omits both.
        let request = api.transport.calls("session/create")[0].args["request"] ?? .null
        assert(request["sessionId"].string.hasPrefix("session-"), "the create requests its own session identity")
        assert(request["workspaceId"] == .null, "no workspace omits workspaceId")
        assert(request["agentPreset"] == .null, "the default omits agentPreset")
        api.transport.calls("session/create")[0].fail(HarnessError(message: "the gateway refused the create"))
        let result = await task.value
        assert(result.outcome == .failed("the gateway refused the create"), "the failed create is reported as this create's failure")
        assert(store.selectedID == "sA", "the failed create keeps the previously selected session")
        assert(store.newlyCreatedSession == nil, "the failed create captures no composer focus")
        assert(store.error == "the gateway refused the create", "the failure is reported to the user")
        assert(api.transport.calls("session/list").count == 0, "the failed create refreshes no list")
        assert(store.createSeat.active == nil, "the create releases its seat")
        assert(!result.dismissesSheet, "the old view's bug: a selected session made the sheet close on a failure")
        print("PASS: a failed create keeps the old selection and closes no sheet")
    }

    // (6) Production: the sheet's close. The first sheet issues a create and
    // is closed - Cancel or a swipe, the production seam NewTaskView uses -
    // before its answer lands; the user reopens the sheet without pressing
    // Create. The retired create's parked answer settles stale and applies
    // nothing, and the reopened sheet's own create still applies exactly once.
    @MainActor
    static func prodSheetCloseStalesInFlightCreate() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        // The first sheet instance issues a create...
        let first = Task { @MainActor in await store.create(workspaceID: nil, presetID: "p-old") }
        await spin { api.transport.calls("session/create").count == 1 }
        let firstRequest = api.transport.calls("session/create")[0].args["request"]?.object
        assert(firstRequest?["agentPreset"]?.string == "p-old",
               "the explicit choice sends the exact advertised id")
        // ...and the sheet is closed before its answer lands: the production
        // close seam retires the in-flight create.
        store.retireCreate()
        assert(store.createSeat.active == nil, "the close retires the in-flight create's seat")
        // The user reopens the sheet and does not press Create yet. The
        // parked answer lands now: it belongs to the closed sheet and must
        // apply nothing.
        api.transport.calls("session/create")[0].respond(created("c-old", preset: "p-old"))
        let firstResult = await first.value
        assert(firstResult.outcome == .stale, "the closed sheet's create settles stale")
        assert(store.selectedID == nil, "the closed sheet's answer selects nothing")
        assert(api.transport.calls("session/list").count == 0, "the closed sheet's answer issues no list")
        assert(store.sessions.count == 1, "the closed sheet's answer refreshes no list")
        assert(store.error == nil && store.newlyCreatedSession == nil, "the closed sheet's answer writes no error and no focus")
        assert(!firstResult.dismissesSheet, "the closed sheet's answer closes no sheet")
        // The reopened sheet presses Create: the seat is free and the new
        // create applies exactly once.
        let second = Task { @MainActor in await store.create(workspaceID: nil, presetID: "p-new") }
        await spin { api.transport.calls("session/create").count == 2 }
        api.transport.calls("session/create")[1].respond(created("c-new", preset: "p-new"))
        await spin { api.transport.calls("session/list").count == 1 }
        api.transport.calls("session/list")[0].respond(list(["sA", "c-new"]))
        let secondResult = await second.value
        assert(secondResult.outcome == .created(sessionID: "c-new", agentPreset: "p-new"), "the reopened sheet's create is confirmed with its own answer")
        assert(store.selectedID == "c-new", "the reopened create's session is selected")
        assert(store.sessions.count == 2, "the reopened create refreshed the list")
        assert(store.newlyCreatedSession == "c-new", "focus lands on the reopened create's session")
        assert(secondResult.dismissesSheet, "the confirmed success closes its own sheet")
        print("PASS: closing the sheet stales the in-flight create; the reopened sheet creates")
    }

    // (7) Production: overlapping creates, both answer orders. The
    // superseded create always settles stale and applies nothing; exactly one
    // create is confirmed, exactly one list refresh lands, and the focus and
    // the selection belong to the live create.
    @MainActor
    static func prodOverlapBothOrders() async throws {
        try await prodOverlap(staleFirst: true)
        try await prodOverlap(staleFirst: false)
        print("PASS: overlapping creates settle stale in both answer orders")
    }

    @MainActor
    static func prodOverlap(staleFirst: Bool) async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        var aSettled = false
        let a = Task { @MainActor in
            defer { aSettled = true }
            return await store.create(workspaceID: nil, presetID: "p-a") }
        await spin { api.transport.calls("session/create").count == 1 }
        let b = Task { @MainActor in await store.create(workspaceID: nil, presetID: "p-b") }
        await spin { api.transport.calls("session/create").count == 2 }
        // a's request is the superseded one: b's begin took the seat.
        let staleAnswer = api.transport.calls("session/create")[0]
        let liveAnswer = api.transport.calls("session/create")[1]
        var staleResult: CreateResult!
        var liveResult: CreateResult!
        if staleFirst {
            staleAnswer.respond(created("cA", preset: "p-a"))
            await spin { aSettled || api.transport.calls("session/list").count >= 1 }
            if !aSettled { api.transport.calls("session/list")[0].respond(list(["sA", "cB"])) }
            staleResult = await a.value
            assert(staleResult.outcome == .stale, "the superseded answer settles stale")
            assert(store.selectedID == nil && store.sessions.count == 1 && store.error == nil && store.newlyCreatedSession == nil,
                   "the superseded answer applies nothing")
            liveAnswer.respond(created("cB", preset: "p-b"))
            await spin { api.transport.calls("session/list").count == 1 }
            api.transport.calls("session/list")[0].respond(list(["sA", "cB"]))
            liveResult = await b.value
        } else {
            liveAnswer.respond(created("cB", preset: "p-b"))
            await spin { api.transport.calls("session/list").count == 1 }
            api.transport.calls("session/list")[0].respond(list(["sA", "cB"]))
            liveResult = await b.value
            assert(liveResult.outcome == .created(sessionID: "cB", agentPreset: "p-b"), "the live create is confirmed")
            assert(store.selectedID == "cB" && store.sessions.count == 2, "the live create applied before the stale answer")
            staleAnswer.respond(created("cA", preset: "p-a"))
            await spin { aSettled || api.transport.calls("session/list").count >= 2 }
            if !aSettled { api.transport.calls("session/list")[1].respond(list(["sA", "cB"])) }
            staleResult = await a.value
            assert(staleResult.outcome == .stale, "the late superseded answer settles stale")
            assert(store.selectedID == "cB", "the late answer does not steal the selection")
            assert(api.transport.calls("session/list").count == 1, "the late answer refreshes no second list")
            assert(store.error == nil && store.newlyCreatedSession == "cB", "the late answer writes no error and no focus")
        }
        assert(liveResult.outcome == .created(sessionID: "cB", agentPreset: "p-b"), "exactly one create is confirmed")
        assert(store.selectedID == "cB" && store.sessions.count == 2, "exactly one create applied its selection and its list")
        assert(api.transport.calls("session/list").count == 1, "exactly one list refresh")
        assert(store.newlyCreatedSession == "cB", "focus belongs to the live create")
        assert(liveResult.dismissesSheet && !staleResult.dismissesSheet, "only the confirmed create closes a sheet")
    }

    // (8) Production: A -> B -> A. The seat dies on the first switch and
    // never comes back; the original answer lands on the original session and
    // is stale - no selection theft, no list refresh, no error, no focus. A
    // new create on the same session still applies.
    @MainActor
    static func prodAToBToADoesNotSteal() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        await store.select("sA")
        var done = false
        let task = Task { @MainActor in
            defer { done = true }
            return await store.create(workspaceID: nil, presetID: nil) }
        await spin { api.transport.calls("session/create").count == 1 }
        await store.select("sB")
        assert(store.createSeat.active == nil, "the session switch drops the in-flight create's seat")
        await store.select("sA")
        api.transport.calls("session/create")[0].respond(created("c1", preset: nil))
        // A broken owner would refresh for the stale create; answer that list
        // with the unchanged world so the breakage runs to completion.
        await spin { done || api.transport.calls("session/list").count >= 1 }
        if !done { api.transport.calls("session/list")[0].respond(list(["sA", "sB"])) }
        let result = await task.value
        assert(result.outcome == .stale, "A -> B -> A settles the original create stale")
        assert(store.selectedID == "sA", "the selection stays where the user left it")
        assert(store.sessions.count == 2, "no list refresh")
        assert(store.error == nil && store.newlyCreatedSession == nil, "no error, no focus")
        assert(!result.dismissesSheet, "the stale answer closes no sheet")
        let again = Task { @MainActor in await store.create(workspaceID: nil, presetID: nil) }
        await spin { api.transport.calls("session/create").count == 2 }
        api.transport.calls("session/create")[1].respond(created("c2", preset: nil))
        await spin { api.transport.calls("session/list").count == 1 }
        api.transport.calls("session/list")[0].respond(list(["sA", "sB", "c2"]))
        let againResult = await again.value
        assert(againResult.outcome == .created(sessionID: "c2", agentPreset: nil), "a new create after A -> B -> A still applies")
        assert(store.selectedID == "c2" && store.sessions.count == 3, "the new create selected and refreshed")
        print("PASS: A -> B -> A cannot let an old create steal the selection")
    }

    // (9) Production: reconnect. The dead connection's answer settles stale
    // and applies nothing; the new connection's create applies.
    @MainActor
    static func prodReconnectStalesOldAnswer() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        let task = Task { @MainActor in await store.create(workspaceID: nil, presetID: nil) }
        await spin { api.transport.calls("session/create").count == 1 }
        store.disconnect()
        assert(store.api == nil && !store.connected, "the disconnect dropped the api")
        api.transport.calls("session/create")[0].respond(created("c-old", preset: nil))
        let result = await task.value
        assert(result.outcome == .stale, "the dead connection's answer settles stale")
        assert(store.selectedID == nil && store.sessions.count == 1, "the stale answer applies nothing")
        assert(store.error == nil && store.newlyCreatedSession == nil, "the stale answer writes no error and no focus")
        assert(!result.dismissesSheet, "the stale answer closes no sheet")
        let api2 = FakeAPI()
        wire(store, api2, sessions: ["sA"])
        let again = Task { @MainActor in await store.create(workspaceID: nil, presetID: nil) }
        await spin { api2.transport.calls("session/create").count == 1 }
        api2.transport.calls("session/create")[0].respond(created("c-new", preset: nil))
        await spin { api2.transport.calls("session/list").count == 1 }
        api2.transport.calls("session/list")[0].respond(list(["sA", "c-new"]))
        let againResult = await again.value
        assert(againResult.outcome == .created(sessionID: "c-new", agentPreset: nil), "the new connection's create applies")
        assert(store.selectedID == "c-new", "the new create selected its session")
        print("PASS: a reconnect stales the old answer, and the new connection creates")
    }

    // (10) Production: session/workspace-attach-failed. The Host created the
    // session but could not attach it to the workspace: the list is refreshed
    // on the same live connection and the session becomes visible; the
    // outcome is attachFailed - not a success, not a retry, no selection,
    // no focus, no sheet close.
    @MainActor
    static func prodAttachFailedRefreshesOnly() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA"])
        await store.select("sA")
        let task = Task { @MainActor in await store.create(workspaceID: "w1", presetID: nil) }
        await spin { api.transport.calls("session/create").count == 1 }
        let attachRequest = api.transport.calls("session/create")[0].args["request"]?.object
        assert(attachRequest?["workspaceId"]?.string == "w1",
               "the requested workspace travels on the wire")
        api.transport.calls("session/create")[0].fail(HarnessError(
            message: "session was created but could not attach to workspace",
            code: "session/workspace-attach-failed",
            details: .object(["sessionId": .string("cAtt"), "workspaceId": .string("w1")])))
        // The allowed action: a list refresh on this same live connection.
        await spin { api.transport.calls("session/list").count == 1 }
        api.transport.calls("session/list")[0].respond(list(["sA", "cAtt"]))
        let result = await task.value
        assert(result.outcome == .attachFailed(sessionID: "cAtt", workspaceID: "w1"), "attach-failed is its own outcome, not a success")
        assert(store.selectedID == "sA", "attach-failed selects nothing")
        assert(store.newlyCreatedSession == nil, "attach-failed captures no composer focus")
        assert(store.error == "session was created but could not attach to workspace", "the reason is reported")
        assert(store.sessions.contains { $0.id == "cAtt" }, "the refreshed list shows the created session")
        assert(api.transport.calls("session/create").count == 1, "no automatic retry")
        assert(!result.dismissesSheet, "attach-failed closes no sheet")
        print("PASS: attach-failed refreshes the list on the same connection and nothing else")
    }

    // (11) Production: attach-failed across a switch. The create's allowed
    // list refresh parks; while it is parked the user switches sessions, so
    // the create no longer owns the seat. The parked refresh writes no list
    // and no error, and the create settles stale - not attach-failed - and
    // closes no sheet.
    @MainActor
    static func prodAttachFailedParkedRefreshStalesOnSwitch() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        let task = Task { @MainActor in await store.create(workspaceID: "w1", presetID: nil) }
        await spin { api.transport.calls("session/create").count == 1 }
        api.transport.calls("session/create")[0].fail(HarnessError(
            message: "session was created but could not attach to workspace",
            code: "session/workspace-attach-failed",
            details: .object(["sessionId": .string("cAtt"), "workspaceId": .string("w1")])))
        // The allowed refresh is issued...
        await spin { api.transport.calls("session/list").count == 1 }
        // ...and parks. While it is parked, the user switches sessions: the
        // switch drops the in-flight create's seat.
        await store.select("sB")
        assert(store.createSeat.active == nil, "the switch drops the in-flight create's seat")
        // The parked list lands: the create no longer owns it, so it writes
        // no list and no error, and the create settles stale.
        api.transport.calls("session/list")[0].respond(list(["sA", "sB", "cAtt"]))
        let result = await task.value
        assert(result.outcome == .stale, "a switch during the attach-failed refresh stales the create")
        assert(store.selectedID == "sB", "the switch's selection stands")
        assert(store.sessions.count == 2, "the create's parked refresh refreshed no list")
        assert(store.error == nil, "the create's parked refresh wrote no error")
        assert(store.newlyCreatedSession == nil, "the create captured no composer focus")
        assert(!result.dismissesSheet, "the staled attach-failed closes no sheet")
        print("PASS: a switch during the attach-failed refresh stales the create and writes nothing")
    }

    // (12) Production: the create's own select. Its follow parks on a slow
    // socket while the user switches sessions. The old create must settle
    // stale - no .created, no dismiss, no focus, no selection theft - while
    // a legitimate select still settles .created.
    @MainActor
    static func prodFollowParkSwitchStalesCreate() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        let transport = ParkedTransport()
        store.followTransport = transport
        store.carrier.beginAttempt(index: 1)
        let task = Task { @MainActor in await store.create(workspaceID: nil, presetID: nil) }
        await spin { api.transport.calls("session/create").count == 1 }
        api.transport.calls("session/create")[0].respond(created("c1", preset: nil))
        await spin { api.transport.calls("session/list").count == 1 }
        api.transport.calls("session/list")[0].respond(list(["sA", "sB", "c1"]))
        // The create's select is live: it rotated the epoch, retired the
        // seat, selected its session, and parked in the follow's subscribe.
        await spin { transport.sent.count == 1 && store.selectedID == "c1" }
        assert(transport.sent[0]["endpoint"].string == "session/follow",
               "the follow is pointed at the create's session")
        // While the follow is parked, the user switches sessions: the
        // switch's subscribe retires the old stream and parks on its own
        // open frame.
        let switchTask = Task<Void, Never> { @MainActor in await store.select("sB") }
        await spin { store.selectedID == "sB" && transport.sent.count == 2 }
        // The old follow is released: the old create's select completes and
        // must see the switch's selection, not its own.
        transport.release(0)
        let result = await task.value
        assert(result.outcome == .stale, "a switch during the create's follow stales the create")
        assert(store.selectedID == "sB", "the switch's selection stands, the create stole nothing back")
        assert(store.error == nil && store.newlyCreatedSession == nil, "the staled follow wrote no error and no focus")
        assert(!result.dismissesSheet, "the staled follow closes no sheet")
        // Release the switch's follow so it completes too.
        transport.release(1)
        await spin { transport.sent.count == 3 }
        transport.release(2)
        await switchTask.value
        // A legitimate create still settles .created: a fresh sheet, a fresh
        // operation, no switch in flight.
        store.carrier.beginAttempt(index: 2)
        let again = Task { @MainActor in await store.create(workspaceID: nil, presetID: nil) }
        await spin { api.transport.calls("session/create").count == 2 }
        api.transport.calls("session/create")[1].respond(created("c2", preset: nil))
        await spin { api.transport.calls("session/list").count == 2 }
        api.transport.calls("session/list")[1].respond(list(["sA", "sB", "c1", "c2"]))
        await spin { transport.sent.count == 4 }
        transport.release(3)
        let againResult = await again.value
        assert(againResult.outcome == .created(sessionID: "c2", agentPreset: nil), "a legitimate create still settles created")
        assert(store.selectedID == "c2" && store.newlyCreatedSession == "c2", "the legitimate create selected and focused")
        assert(againResult.dismissesSheet, "the legitimate create closes its sheet")
        print("PASS: a switch during the create's follow stales it; a legitimate create still applies")
    }

    // (13) Production: the sheet's close during the create's own follow. The
    // self-select keeps the seat while its follow parks on a slow socket; the
    // production close seam (NewTaskView's Cancel and onDismiss) retires it,
    // so the late follow settles stale, and the reopened sheet's create still
    // settles created.
    @MainActor
    static func prodSheetCloseDuringFollowStalesCreate() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        let transport = ParkedTransport()
        store.followTransport = transport
        store.carrier.beginAttempt(index: 1)
        let task = Task { @MainActor in await store.create(workspaceID: nil, presetID: nil) }
        await spin { api.transport.calls("session/create").count == 1 }
        api.transport.calls("session/create")[0].respond(created("c1", preset: nil))
        await spin { api.transport.calls("session/list").count == 1 }
        api.transport.calls("session/list")[0].respond(list(["sA", "sB", "c1"]))
        // The self-select is live: the seat is still held and the follow is
        // parked.
        await spin { transport.sent.count == 1 && store.selectedID == "c1" }
        assert(store.createSeat.active != nil, "the self-select kept the in-flight create's seat")
        // The sheet closes while the create's own follow is parked...
        store.retireCreate()
        assert(store.createSeat.active == nil, "the close retires the in-flight create's seat")
        // ...and the follow settles with no sheet behind it: stale.
        transport.release(0)
        let result = await task.value
        assert(result.outcome == .stale, "a sheet close during the create's own follow stales the create")
        assert(store.selectedID == "c1", "the stale outcome undoes no selection")
        assert(store.error == nil && store.newlyCreatedSession == nil, "the stale outcome writes no error and no focus")
        assert(!result.dismissesSheet, "the stale outcome closes no sheet")
        // The reopened sheet presses Create: a fresh operation takes the free
        // seat and settles created.
        store.carrier.beginAttempt(index: 2)
        let again = Task { @MainActor in await store.create(workspaceID: nil, presetID: nil) }
        await spin { api.transport.calls("session/create").count == 2 }
        api.transport.calls("session/create")[1].respond(created("c2", preset: nil))
        await spin { api.transport.calls("session/list").count == 2 }
        api.transport.calls("session/list")[1].respond(list(["sA", "sB", "c1", "c2"]))
        await spin { transport.sent.count == 2 && store.selectedID == "c2" }
        transport.release(1)
        let againResult = await again.value
        assert(againResult.outcome == .created(sessionID: "c2", agentPreset: nil), "the reopened sheet's create still settles created")
        assert(store.selectedID == "c2" && store.newlyCreatedSession == "c2", "the reopened create selected and focused")
        assert(againResult.dismissesSheet, "the reopened create closes its sheet")
        print("PASS: a sheet close during the create's own follow stales it; the reopened sheet creates")
    }

    // (14) Production: A -> B -> A during the create's own follow. The first
    // switch retires the seat; when the selection returns to the create's
    // session the id matches again - but the seat is gone, so the old
    // operation's late follow settles stale and cannot revive it.
    @MainActor
    static func prodFollowParkABACannotReviveCreate() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        let transport = ParkedTransport()
        store.followTransport = transport
        store.carrier.beginAttempt(index: 1)
        let task = Task { @MainActor in await store.create(workspaceID: nil, presetID: nil) }
        await spin { api.transport.calls("session/create").count == 1 }
        api.transport.calls("session/create")[0].respond(created("c1", preset: nil))
        await spin { api.transport.calls("session/list").count == 1 }
        api.transport.calls("session/list")[0].respond(list(["sA", "sB", "c1"]))
        // The self-select parked its follow...
        await spin { transport.sent.count == 1 && store.selectedID == "c1" }
        // ...and the user switches away and back while it is still parked.
        let away = Task<Void, Never> { @MainActor in await store.select("sB") }
        await spin { store.selectedID == "sB" && transport.sent.count == 2 }
        let back = Task<Void, Never> { @MainActor in await store.select("c1") }
        await spin { store.selectedID == "c1" && transport.sent.count == 3 }
        // The old follow settles now: the selection matches its session again,
        // but its seat died on the first switch.
        transport.release(0)
        let result = await task.value
        assert(result.outcome == .stale, "an A -> B -> A during the create's follow cannot revive it")
        assert(store.selectedID == "c1", "the user's own switch-back selection stands")
        assert(store.error == nil && store.newlyCreatedSession == nil, "the staled ABA writes no error and no focus")
        assert(!result.dismissesSheet, "the staled ABA closes no sheet")
        // The user's own switches settle behind it: the away-switch finds
        // its stream already replaced by the switch-back and settles with no
        // frame of its own; the switch-back's guard passes and opens the
        // selection the user actually made.
        transport.release(1)
        await away.value
        transport.release(2)
        await spin { transport.sent.count == 4 }
        transport.release(3)
        await back.value
        print("PASS: an A -> B -> A during the create's follow stales the old create")
    }

    // (15) Production: a newer create while the old create's follow is
    // parked. The close frees the seat, the reopened sheet's create takes it,
    // and the old follow - settling late - is stale: it overwrites neither
    // the newer create's settled outcome, its focus, nor its sheet.
    @MainActor
    static func prodFollowParkNewerCreateKeepsOutcome() async throws {
        let api = FakeAPI()
        let store = PocketStore(restoringPrimary: false)
        wire(store, api, sessions: ["sA", "sB"])
        let transport = ParkedTransport()
        store.followTransport = transport
        store.carrier.beginAttempt(index: 1)
        let task = Task { @MainActor in await store.create(workspaceID: nil, presetID: nil) }
        await spin { api.transport.calls("session/create").count == 1 }
        api.transport.calls("session/create")[0].respond(created("c1", preset: nil))
        await spin { api.transport.calls("session/list").count == 1 }
        api.transport.calls("session/list")[0].respond(list(["sA", "sB", "c1"]))
        // The old create's self-select parked its follow, seat still held.
        await spin { transport.sent.count == 1 && store.selectedID == "c1" }
        // The sheet closes and reopens; the new create takes the free seat.
        store.retireCreate()
        let again = Task { @MainActor in await store.create(workspaceID: nil, presetID: nil) }
        await spin { api.transport.calls("session/create").count == 2 }
        api.transport.calls("session/create")[1].respond(created("c2", preset: nil))
        await spin { api.transport.calls("session/list").count == 2 }
        api.transport.calls("session/list")[1].respond(list(["sA", "sB", "c1", "c2"]))
        // The new create's self-select cancelled the old stream and parked in
        // its own follow.
        await spin { transport.sent.count == 2 && store.selectedID == "c2" }
        // The newer create settles first...
        transport.release(1)
        await spin { transport.sent.count == 3 }
        transport.release(2)
        let againResult = await again.value
        assert(againResult.outcome == .created(sessionID: "c2", agentPreset: nil), "the newer create still settles created")
        assert(store.newlyCreatedSession == "c2", "the newer create focused its session")
        assert(againResult.dismissesSheet, "the newer create closes its sheet")
        assert(store.createSeat.settled?.operation.id == againResult.operation.id, "the newer create's outcome is the settled one")
        // ...and the old follow settles late: stale, overwriting nothing.
        transport.release(0)
        let result = await task.value
        assert(result.outcome == .stale, "the old create's late follow stales behind the newer create")
        assert(store.selectedID == "c2", "the newer create's selection stands")
        assert(store.newlyCreatedSession == "c2", "the old follow wrote no focus over the newer one")
        assert(store.createSeat.settled?.operation.id == againResult.operation.id
               && store.createSeat.settled?.outcome == .created(sessionID: "c2", agentPreset: nil),
               "the settled outcome still belongs to the newer create")
        print("PASS: a newer create keeps its outcome over the old create's late follow")
    }

    /// A bounded read-only observation of the store state a create must
    /// not disturb: the selection identity on the store and the connection,
    /// the composer's draft, attachments and focus, the visible rows, the
    /// native transcript, requests, queue, diff, interactions and
    /// capabilities, the model, the catalog, the loading state and the
    /// pending request. The checks freeze it before a create and compare it
    /// after - semantic equivalence of the full prior presentation, not
    /// just the two selection IDs.
    @MainActor
    private struct PresentationState: Equatable {
        let selectedID: String?
        let nativeSelectedID: String?
        let draft: String
        let images: Int
        let rows: Int
        let nativeRows: Int
        let nativeRequests: Int
        let nativeQueue: Int
        let nativeQueueOmitted: Int
        let nativeProtocolNotices: Int
        var interactions: Int
        let nativeCompactionPending: Bool
        let supportsCompaction: Bool
        let supportsQueue: Bool
        let supportsDiff: Bool
        let nativeDiff: NativeDiffInfo?
        let model: JSON
        let catalog: JSON
        let loadingHistory: Bool
        var nativeReady: Bool
        let readingMode: Bool
        let hasMore: Bool
        let pendingText: String?
        let newlyCreatedSession: String?
        let composerFocusRequest: UUID?
        init(_ store: PocketStore) {
            selectedID = store.selectedID
            nativeSelectedID = store.native?.selectedID
            draft = store.draft
            images = store.images.count
            rows = store.rows.count
            nativeRows = store.nativeTranscriptObservation.rows.count
            nativeRequests = store.nativeRequests.count
            nativeQueue = store.nativeQueue.count
            nativeQueueOmitted = store.nativeQueueOmitted
            nativeProtocolNotices = store.nativeProtocolNotices.count
            interactions = store.interactions.count
            nativeCompactionPending = store.nativeCompactionPending
            supportsCompaction = store.nativeSupportsCompaction
            supportsQueue = store.nativeSupportsQueue
            supportsDiff = store.nativeSupportsDiff
            nativeDiff = store.nativeDiff
            model = store.model
            catalog = store.catalog
            loadingHistory = store.loadingHistory
            nativeReady = store.nativeReady
            readingMode = store.readingMode
            hasMore = store.hasMore
            pendingText = store.pendingText
            newlyCreatedSession = store.newlyCreatedSession
            composerFocusRequest = store.composerFocusRequest
        }
    }
    /// Freeze a meaningful prior native presentation: the prior session in
    /// the roster and selected, its shell, model, capabilities and folded
    /// transcript, a composer row, a draft, a pending request and an
    /// interaction - the state a create must leave untouched. The store's
    /// own production event path builds it, not a private write.
    @MainActor
    private static func seedPriorState(_ store: PocketStore) {
        store.sessions = [HarnessSession(raw: .object(["sessionId": .string("prior"), "cwd": .string("/w"), "updatedAt": .number(1), "running": .bool(false)]))]
        store.selectedID = "prior"
        store.native?.selectedID = "prior"
        store.catalog = .object(["default": .object(["provider": .string("native"), "model": .string("default-model")])])
        store.receiveNative(NativeEvent(op: "opened", session: "prior", model: "prior-model", workspace: "/w",
                                        capabilities: [NativeCompactionInfo.capability, NativeQueueInfo.capability, NativeDiffInfo.capability]))
        store.receiveNative(NativeEvent(op: "user", session: "prior", text: "prior prompt", sequence: 1))
        store.receiveNative(NativeEvent(op: "text", session: "prior", text: "prior reply", sequence: 2))
        // The history load is done: set it directly - the seed's synced
        // event would also make the shell report its terminal size over the
        // socketless test connection, surfacing a send error the create
        // must not be blamed for.
        store.nativeReady = true
        store.loadingHistory = false
        store.draft = "prior draft"
        store.rows = [TranscriptRow(id: "prior-1", kind: .user, text: "prior row")]
        store.nativeRequests = [NativeRequestInfo(fields: ["id": .string("req-1")])]
        store.interactions = [Interaction(raw: .object(["agentId": .string("prior")]), clientID: "prior-1")]
    }

    // (16) Production: a rejected native open is a visible failure that
    // adopts nothing. A frozen prior presentation - selection, draft, rows,
    // transcript, capabilities, model, loading - must stand untouched, with
    // one open frame for the create's own session and none for the prior
    // one (no auto-retry), no focus, and the sheet's dismiss rule closed.
    @MainActor
    static func prodNativeCreateOpenFailure() async throws {
        let store = PocketStore(restoringPrimary: false)
        store.connected = true
        store.native = RecordingNativeConnection()
        seedPriorState(store)
        let before = PresentationState(store)
        var opened: [NativeCommand] = []
        store.nativeOpenSeam = { command in opened.append(command); throw HarnessError(message: "Native Harness is disconnected") }
        let result = await store.create(workspaceID: nil)
        if case .failed(let message) = result.outcome {
            assert(message == "Native Harness is disconnected",
                   "the failure is the rejected open's error")
        } else {
            assert(false, "a rejected native open must settle failed, not created")
        }
        assert(!result.dismissesSheet, "a failed native create closes no sheet")
        assert(store.error == "Native Harness is disconnected",
               "the rejected open's error is visible")
        assert(opened.count == 1 && opened[0].op == "open" && opened[0].session != "prior",
               "one open for the create's own session, never a re-open of the prior one")
        assert(store.createSeat.active == nil, "the failed native create released its seat")
        assert(store.createSeat.settled?.operation.id == result.operation.id
               && store.createSeat.settled?.outcome == result.outcome,
               "the settled outcome is the failed native create's")
        assert(PresentationState(store) == before,
               "the failed create left the prior presentation untouched")
        print("PASS: a rejected native open settles failed, keeps the prior selection, no focus, no auto-retry, no dismiss")
    }

    // (17) Production: the native create's real success. The send confirms
    // the local socket write; the host's answer to the open is what settles
    // it - and only then - the commit adopts the new session exactly once:
    // the full transition applied locally, one open frame, no second open -
    // and only then the default task path focuses its composer. The
    // host's answer, parked by the open's buffer, must then replay
    // through the production admission path - the event race stays
    // coherent on the new selection - and the commit must have saved the
    // prior draft for the round trip.
    @MainActor
    static func prodNativeCreateOpenSuccess() async throws {
        let store = PocketStore(restoringPrimary: false)
        store.connected = true
        store.native = RecordingNativeConnection()
        seedPriorState(store)
        var opened: [NativeCommand] = []
        store.nativeOpenSeam = { command in opened.append(command) }
        let focus = store.composerFocusRequest
        let task = Task { @MainActor in await store.createDefaultTask() }
        await spin { opened.count == 1 }
        guard let id = opened[0].session else {
            assert(false, "the confirmed open names the create's own session")
            return
        }
        // The host's answer to the confirmed open lands now: opened and
        // synced for the new session. The create suspends on that decision
        // - the socket write is not its success - and the commit replays
        // the answer through the production admission path.
        store.receiveNative(NativeEvent(op: "opened", session: id, model: "Host model", workspace: "/w",
                                        capabilities: [NativeCompactionInfo.capability, NativeQueueInfo.capability]))
        store.receiveNative(NativeEvent(op: "synced", session: id))
        _ = await task.value
        guard case .created(let createdID, let preset) = store.createSeat.settled?.outcome else {
            assert(false, "the confirmed native open must settle created")
            return
        }
        assert(createdID == id && preset == nil,
               "the create carries no wire preset and adopts its own session")
        assert(opened.count == 1 && opened[0].op == "open",
               "one confirmed open for the create's own session, adopted exactly once")
        assert(store.selectedID == id && store.native!.selectedID == id,
               "the commit adopted the generated session on the store and the connection")
        assert(store.draft == "" && store.rows.isEmpty && store.nativeTranscriptObservation.rows.isEmpty,
               "the commit reset the presentation for the new session")
        assert(store.nativeReady && !store.loadingHistory,
               "the host's synced replayed into the commit finished the history load")
        assert(store.nativeShell?.id == id, "the opened event was admitted for the committed session")
        assert(store.sessions.contains(where: { $0.id == id }), "the roster gained the new session")
        assert(store.nativeSupportsCompaction && store.nativeSupportsQueue && !store.nativeSupportsDiff,
               "the new session's capabilities folded, not the prior ones")
        assert(store.newlyCreatedSession == nil, "the default task path consumed the focus")
        assert(store.composerFocusRequest != nil && store.composerFocusRequest != focus,
               "the confirmed open focused the new session's composer")
        assert(store.createSeat.active == nil, "the confirmed native create released its seat")
        // The commit saved the prior draft for its session: selecting it
        // back brings the draft with it.
        await store.select("prior")
        assert(store.draft == "prior draft", "the commit saved the prior draft for the round trip")
        print("PASS: the confirmed native open settles created and the default task path focuses")
    }

    // (18) Production: a parked native open. Before the open confirms, the
    // create has published and adopted nothing - a frozen prior presentation
    // stands untouched even while the frame is in flight. A sheet close
    // during the open stales the create - no error, no focus, no dismiss,
    // presentation intact - whether the open later succeeds or fails; the
    // host's events for the abandoned session then admit against the old
    // selection and are dropped, not folded. A supersede parks the older
    // create's open under the newer create, and the newer create keeps its
    // full state, outcome and focus while the older open lands late -
    // failing or not, the old open writes nothing over it.
    @MainActor
    static func prodNativeCreateParkedOpen() async throws {
        let store = PocketStore(restoringPrimary: false)
        store.connected = true
        store.native = RecordingNativeConnection()
        seedPriorState(store)
        let before = PresentationState(store)
        let seam = ParkedNativeOpen()
        store.nativeOpenSeam = { [seam] command in try await seam.send(command) }
        // The first sheet's open is parked; while it is in flight the
        // create has adopted nothing - the frozen presentation stands.
        let first = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { seam.sent.count == 1 }
        assert(seam.sent[0].op == "open" && seam.sent[0].session != nil,
               "the parked open is the first create's own session")
        assert(store.createSeat.active != nil, "the create kept its seat across the parked open")
        assert(PresentationState(store) == before,
               "an in-flight open adopts nothing: the prior presentation stands")
        // The sheet is closed before the open lands: stale - no error, no
        // focus, no dismiss, and the full prior presentation intact.
        store.retireCreate()
        assert(store.createSeat.active == nil, "the close retires the in-flight create's seat")
        seam.release(0)
        let firstResult = await first.value
        assert(firstResult.outcome == .stale, "a sheet close during the native open stales the create")
        assert(store.error == nil, "the closed sheet's open writes no error")
        assert(!firstResult.dismissesSheet, "the closed sheet's open closes no sheet")
        assert(PresentationState(store) == before,
               "the stale late success left the prior selection and its full presentation")
        // The host still answers the abandoned session's open: its
        // opened/synced events admit against the old selection and must be
        // dropped, not folded.
        store.receiveNative(NativeEvent(op: "opened", session: seam.sent[0].session, model: "Host model", workspace: "/w",
                                        capabilities: [NativeCompactionInfo.capability]))
        store.receiveNative(NativeEvent(op: "synced", session: seam.sent[0].session))
        assert(store.nativeShell?.id == "prior", "the abandoned session's opened event was not admitted")
        assert(store.error == nil, "the abandoned session's events wrote no error")
        assert(PresentationState(store) == before,
               "the abandoned session's events left the prior presentation untouched")
        // The reopened sheet's open is parked too, and the sheet is closed
        // before it lands - and the open then fails: stale, and the late
        // failure must not publish a global error over the closed sheet.
        let second = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { seam.sent.count == 2 }
        assert(store.createSeat.active != nil, "the reopened sheet's create kept its seat")
        store.retireCreate()
        seam.fail(1, HarnessError(message: "Native Harness is disconnected"))
        let secondResult = await second.value
        assert(secondResult.outcome == .stale, "the closed sheet's failing open stales the create")
        assert(store.error == nil, "the closed sheet's late failure writes no error")
        assert(!secondResult.dismissesSheet, "the closed sheet's open closes no sheet")
        assert(PresentationState(store) == before,
               "the stale late failure left the prior selection and its full presentation")
        // A supersede parks the older create's open under the newer create;
        // only the newer create may settle, and the older open's late
        // failure must not touch its full state, outcome or focus.
        let third = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { seam.sent.count == 3 }
        let thirdID = seam.sent[2].session
        let fourth = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { seam.sent.count == 4 }
        let fourthID = seam.sent[3].session
        assert(thirdID != nil && fourthID != nil && thirdID != fourthID,
               "each parked open is its own create's session")
        // The newer open lands first: the host's ack for it arrives on the
        // production path, and only then the newer create settles created...
        seam.release(3)
        store.receiveNative(NativeEvent(op: "opened", session: fourthID!, model: "Host model", workspace: "/w",
                                        capabilities: [NativeCompactionInfo.capability, NativeQueueInfo.capability, NativeDiffInfo.capability]))
        store.receiveNative(NativeEvent(op: "synced", session: fourthID!))
        let fourthResult = await fourth.value
        assert(fourthResult.outcome == .created(sessionID: fourthID!, agentPreset: nil),
               "the newer native create settles created")
        assert(store.selectedID == fourthID && store.newlyCreatedSession == fourthID,
               "selection and focus land on the newer create's session")
        assert(store.draft == "" && store.rows.isEmpty
               && store.nativeTranscriptObservation.rows.isEmpty
               && store.nativeShell?.id == fourthID && store.nativeReady && !store.loadingHistory,
               "the newer create's commit adopted its full state and its ack replayed")
        let afterFourth = PresentationState(store)
        // ...then the superseded open fails late: stale, writing nothing.
        seam.fail(2, HarnessError(message: "Native Harness is disconnected"))
        let thirdResult = await third.value
        assert(thirdResult.outcome == .stale, "the superseded open stales the older create")
        assert(store.createSeat.settled?.operation.id == fourthResult.operation.id
               && store.createSeat.settled?.outcome == .created(sessionID: fourthID!, agentPreset: nil),
               "the settled outcome still belongs to the newer create")
        assert(store.error == nil, "the old late failure wrote no error over the newer create")
        assert(PresentationState(store) == afterFourth,
               "the old late failure left the newer create's full state untouched")
        print("PASS: a close or a supersede during a parked native open stales the old create, failing or not")
    }

    // (19) Production: the host answers the create's open before the send
    // confirmation returns. The connection's independent reader task can
    // decode that answer while the open await is still suspended, when the
    // selection still names the prior session - without the open's buffer
    // the admission gate drops both frames and the new session is left
    // shell-less, stuck at nativeReady=false. With it, the frames park for
    // the open and the await-free commit replays them, so the session
    // lands ready and the host reply is never lost.
    @MainActor
    static func prodNativeCreateEarlyHostReply() async throws {
        let store = PocketStore(restoringPrimary: false)
        store.connected = true
        store.native = RecordingNativeConnection()
        seedPriorState(store)
        var earlyReplies: [String] = []
        store.nativeOpenSeam = { command in
            // The host's answer lands on the production event path while
            // the open await is still suspended.
            store.receiveNative(NativeEvent(op: "opened", session: command.session, model: "Host model", workspace: "/w",
                                            capabilities: [NativeCompactionInfo.capability, NativeQueueInfo.capability]))
            store.receiveNative(NativeEvent(op: "synced", session: command.session))
            earlyReplies.append(command.session ?? "")
        }
        let task = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { !earlyReplies.isEmpty }
        let id = earlyReplies[0]
        let result = await task.value
        assert(result.outcome == .created(sessionID: id, agentPreset: nil),
               "a create whose host answered early still settles created")
        assert(store.selectedID == id, "the selection committed to the early-answered session")
        assert(store.nativeShell?.id == id, "the early opened event was replayed into the new session's shell")
        assert(store.sessions.contains(where: { $0.id == id }), "the roster gained the early-answered session")
        assert(store.nativeReady, "the early synced event finished the history load")
        assert(!store.loadingHistory, "the history load was not left pending")
        assert(store.nativeSupportsCompaction && store.nativeSupportsQueue, "the early capabilities folded into the store")
        assert(store.error == nil, "an early host answer publishes no error")
        print("PASS: a host reply that lands before the open's confirmation is parked and replayed, not lost")
    }

    // (21) Production, the real host envelope: the socket write confirms and
    // only then the host rejects the open - a session-scoped error for the
    // create's own session. The send confirmation is not the create's
    // success: without the host's opened answer the create must settle
    // failed, the rejection must stay visible, the prior presentation must
    // stand untouched, the generated session must never be selected or
    // focused - and the sheet stays open.
    @MainActor
    static func prodNativeCreateHostRejection() async throws {
        let store = PocketStore(restoringPrimary: false)
        store.connected = true
        let recording = RecordingNativeConnection()
        store.native = recording
        seedPriorState(store)
        let before = PresentationState(store)
        let task = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { recording.sent.count == 1 }
        let id = recording.sent[0].session!
        // The host's real envelope for a rejected open: a session-scoped
        // error that arrives after the socket write confirmed.
        store.receiveNative(NativeEvent(op: "error", session: id, text: "Session is busy"))
        let result = await task.value
        guard case .failed(let message) = result.outcome else {
            assert(false, "a host-rejected open must settle failed, not created")
            return
        }
        assert(message == "Session is busy", "the failure carries the host's rejection")
        assert(store.error == "Session is busy", "the rejection stays visible")
        assert(!result.dismissesSheet, "the rejected open closes no sheet")
        assert(store.selectedID == "prior" && store.nativeShell?.id == "prior",
               "the generated session was never selected or focused")
        assert(store.createSeat.active == nil && store.createSeat.settled?.operation.id == result.operation.id
               && store.createSeat.settled?.outcome == result.outcome,
               "the rejected create settled and released its seat")
        assert(PresentationState(store) == before,
               "the rejection left the prior presentation untouched")
        print("PASS: a host-rejected open settles failed after the socket write, keeps the prior presentation, never selects the generated session")
    }

    // (22) Production, the real host envelope in the other order: the send
    // confirmation returns first and only then the host's opened and synced
    // arrive. The create waits for that decision - not the socket write -
    // and settles created once it lands.
    @MainActor
    static func prodNativeCreateHostAckAfterSend() async throws {
        let store = PocketStore(restoringPrimary: false)
        store.connected = true
        let recording = RecordingNativeConnection()
        store.native = recording
        seedPriorState(store)
        let task = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { recording.sent.count == 1 }
        let id = recording.sent[0].session!
        store.receiveNative(NativeEvent(op: "opened", session: id, model: "Host model", workspace: "/w",
                                        capabilities: [NativeCompactionInfo.capability, NativeQueueInfo.capability, NativeDiffInfo.capability]))
        store.receiveNative(NativeEvent(op: "synced", session: id))
        let result = await task.value
        guard case .created(let createdID, let preset) = result.outcome else {
            assert(false, "a host-confirmed open must settle created")
            return
        }
        assert(createdID == id && preset == nil, "the create adopts its own generated session")
        assert(result.dismissesSheet, "the confirmed create closes its sheet")
        assert(store.selectedID == id && store.native!.selectedID == id,
               "the commit adopted the generated session on the store and the connection")
        assert(store.nativeShell?.id == id && store.nativeReady && !store.loadingHistory,
               "the ack replayed into the committed session and finished the load")
        assert(store.sessions.contains(where: { $0.id == id }), "the roster gained the session")
        assert(store.nativeSupportsCompaction && store.nativeSupportsQueue && store.nativeSupportsDiff,
               "the session's capabilities folded")
        print("PASS: a host ack that lands after the send confirmation still settles the create created")
    }

    // (23) Production: the host's early replay is longer than the open's
    // buffer. The decision frames - opened, the terminal synced - must
    // survive the overflow; the history between them is a bounded window.
    // The create still settles created, the shell still lands ready, the
    // buffer is cleared - and the truncation is visible as the host's own
    // gap semantics, not a silently complete transcript.
    @MainActor
    static func prodNativeCreateEarlyReplayOverflow() async throws {
        let store = PocketStore(restoringPrimary: false)
        store.connected = true
        let recording = RecordingNativeConnection()
        store.native = recording
        seedPriorState(store)
        var opened: [NativeCommand] = []
        store.nativeOpenSeam = { command in
            opened.append(command)
            // The host's whole early replay while the send is in flight:
            // far more history than the open's bounded window holds.
            store.receiveNative(NativeEvent(op: "opened", session: command.session, model: "Host model", workspace: "/w",
                                            capabilities: [NativeCompactionInfo.capability, NativeQueueInfo.capability]))
            for i in 0..<300 {
                store.receiveNative(NativeEvent(op: "user", session: command.session, text: "line \(i)", sequence: i + 1))
            }
            store.receiveNative(NativeEvent(op: "synced", session: command.session))
        }
        let task = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { opened.count == 1 }
        let id = opened[0].session!
        let result = await task.value
        guard case .created(let createdID, _) = result.outcome else {
            assert(false, "an overflowing early replay still settles the create created")
            return
        }
        assert(createdID == id, "the create adopted its own session")
        assert(store.selectedID == id && store.nativeShell?.id == id,
               "the shell exists for the committed session")
        assert(store.nativeReady && !store.loadingHistory,
               "the terminal synced survived the overflow and finished the load")
        assert(store.nativeTranscriptObservation.rows.count == 256,
               "the history is a bounded window, not the full replay")
        assert(store.nativeTranscriptObservation.rows.first?.text == ShellPromptContent.parse("line 44").question
               && store.nativeTranscriptObservation.rows.last?.text == ShellPromptContent.parse("line 299").question,
               "the window keeps the newest history and drops the oldest")
        assert(store.error == "Native host retained only part of this conversation. Earlier output is unavailable in this view.",
               "the store surfaces the truncation as a gap")
        assert(store.nativeShell?.error == "Only the retained history is available; earlier output was discarded by the host.",
               "the shell surfaces the truncation as a gap")
        // The buffer is cleared with the create: a live event is admitted
        // against the committed selection, not parked for an open that is
        // gone.
        store.receiveNative(NativeEvent(op: "user", session: id, text: "after the load", sequence: 400))
        assert(store.nativeTranscriptObservation.rows.count == 257,
               "the buffer was cleared: the live event is admitted, not parked")
        print("PASS: an early replay longer than the buffer keeps the decision frames, bounds the history, and surfaces the truncation")
    }

    // (24) Production: the sheet closes while the create waits for the
    // host's decision, and only then does the host answer. The abandoned
    // create must settle stale - not created - and adopt nothing: no
    // selection, no focus, no error, the prior presentation intact.
    @MainActor
    static func prodNativeCreateStaleCloseDuringAck() async throws {
        let store = PocketStore(restoringPrimary: false)
        store.connected = true
        let recording = RecordingNativeConnection()
        store.native = recording
        seedPriorState(store)
        let before = PresentationState(store)
        let task = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { recording.sent.count == 1 }
        let id = recording.sent[0].session!
        store.retireCreate()
        store.receiveNative(NativeEvent(op: "opened", session: id, model: "Host model", workspace: "/w",
                                        capabilities: [NativeCompactionInfo.capability, NativeQueueInfo.capability]))
        store.receiveNative(NativeEvent(op: "synced", session: id))
        let result = await task.value
        assert(result.outcome == .stale, "a sheet close while the ack is in flight stales the create")
        assert(store.error == nil, "the abandoned ack writes no error")
        assert(!result.dismissesSheet, "the abandoned create closes no sheet")
        assert(store.selectedID == "prior" && store.nativeShell?.id == "prior",
               "the answer was not adopted over the prior selection")
        assert(PresentationState(store) == before,
               "the abandoned ack left the prior presentation untouched")
        print("PASS: a sheet close while the host decision is in flight stales the create and adopts nothing")
    }

    // (25) Production: the host's opened answer arrives while the create
    // still owns the sheet - and only then does the sheet close. The
    // parked answer must not be adopted over the closed sheet: the create
    // settles stale, adopts nothing, and the prior presentation stands.
    @MainActor
    static func prodNativeCreateParkedAckThenSheetClose() async throws {
        let store = PocketStore(restoringPrimary: false)
        store.connected = true
        let recording = RecordingNativeConnection()
        store.native = recording
        seedPriorState(store)
        let before = PresentationState(store)
        let task = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { recording.sent.count == 1 }
        let id = recording.sent[0].session!
        // The host's answer arrives while the seat still holds: it parks...
        store.receiveNative(NativeEvent(op: "opened", session: id, model: "Host model", workspace: "/w",
                                        capabilities: [NativeCompactionInfo.capability, NativeQueueInfo.capability]))
        // ...and only then does the sheet close.
        store.retireCreate()
        let result = await task.value
        assert(result.outcome == .stale, "a parked answer must not be adopted after the sheet closes")
        assert(store.error == nil, "the abandoned ack writes no error")
        assert(!result.dismissesSheet, "the abandoned create closes no sheet")
        assert(store.selectedID == "prior" && store.nativeShell?.id == "prior",
               "the parked answer was not adopted over the prior selection")
        assert(PresentationState(store) == before,
               "the abandoned ack left the prior presentation untouched")
        print("PASS: an opened answer parked before the sheet close is dropped with the seat, not adopted")
    }

    // (26) Production: the connection dies after the open's socket write,
    // with no opened and no error ever arriving and no reconnect available
    // (a detached workspace). The create must not wait on the dead
    // connection: the connection failure itself decides it - staled, the
    // seat lost, the parked buffer dropped, the connection's own error
    // visible and un-overwritten, the prior presentation standing except
    // for the connection-level clean-up the failure performs - and neither
    // a late answer nor a later close can change the decided outcome. A
    // fresh create over a recovered connection still succeeds: the decided
    // wait left no stale buffer or continuation behind.
    @MainActor
    static func prodNativeCreateConnectionLossDuringAck() async throws {
        let store = PocketStore(restoringPrimary: false)
        store.connected = true
        store.workspaceDetached = true
        let recording = RecordingNativeConnection()
        store.native = recording
        seedPriorState(store)
        let before = PresentationState(store)
        let task = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { recording.sent.count == 1 }
        let id = recording.sent[0].session!
        // The socket write is confirmed; the socket then dies with no
        // opened and no error, and no reconnect will arrive. The
        // production failure path decides the create on its own.
        store.nativeConnectionFailed("Native connection interrupted: test socket loss")
        let result = await task.value
        assert(result.outcome == .stale, "a connection loss after the open write stales the create")
        assert(store.error == "Native connection interrupted: test socket loss",
               "the connection's own error is visible and un-overwritten")
        assert(!result.dismissesSheet, "the staled create closes no sheet")
        assert(store.selectedID == "prior" && store.nativeShell?.id == "prior",
               "the dead connection adopted nothing")
        assert(store.createSeat.active == nil && store.createSeat.settled?.outcome == .stale,
               "the staled create released its seat with its own outcome")
        var expected = before
        expected.interactions = 0
        expected.nativeReady = false
        assert(PresentationState(store) == expected,
               "the failure clears only the dead connection's own state")
        // A late answer from the dead connection changes nothing...
        store.receiveNative(NativeEvent(op: "opened", session: id, model: "Host model", workspace: "/w",
                                        capabilities: [NativeCompactionInfo.capability, NativeQueueInfo.capability]))
        store.receiveNative(NativeEvent(op: "error", session: id, text: "late rejection"))
        assert(store.selectedID == "prior" && store.nativeShell?.id == "prior",
               "the late frames of a staled open admit nothing")
        assert(store.error == "Native connection interrupted: test socket loss",
               "a late frame overwrites no error")
        // ...and a close over the lost seat decides nothing twice.
        store.retireCreate()
        assert(store.error == "Native connection interrupted: test socket loss",
               "the close over the lost seat writes nothing new")
        // A fresh create over the recovered connection still succeeds: the
        // decided wait left no stale buffer or continuation behind.
        store.workspaceDetached = false
        store.connected = true
        let second = Task { @MainActor in await store.create(workspaceID: nil) }
        await spin { recording.sent.count == 2 }
        let secondID = recording.sent[1].session!
        store.receiveNative(NativeEvent(op: "opened", session: secondID, model: "Host model", workspace: "/w",
                                        capabilities: [NativeCompactionInfo.capability, NativeQueueInfo.capability]))
        store.receiveNative(NativeEvent(op: "synced", session: secondID))
        let secondResult = await second.value
        assert(secondResult.outcome == .created(sessionID: secondID, agentPreset: nil),
               "a fresh create over the recovered connection still succeeds")
        print("PASS: a connection loss after the open write stales the create without a reconnect, without hanging, and adopts nothing")
    }

    // (20) Composition: every presentation of NewTaskView retires the
    // create seat on dismiss, desktop and mobile alike. A presentation that
    // forgot it would let a closed sheet's create settle over a newer
    // selection.
    static func newTaskSheetRetirement() throws {
        guard let path = sourceFile("PocketDSH/HomeView.swift") else {
            throw HarnessError(message: "HomeView.swift not found for the NewTaskView composition check")
        }
        let home = try String(contentsOfFile: path, encoding: .utf8)
        let lines = home.components(separatedBy: "\n")
        let presentations = lines.enumerated().filter { $0.element.contains("NewTaskView()") }
        assert(!presentations.isEmpty, "the NewTaskView presentations are still in HomeView")
        for (index, line) in presentations {
            assert(line.contains("store.retireCreate()"),
                   "HomeView line \(index + 1) retires the create seat when NewTaskView dismisses")
        }
        print("PASS: every NewTaskView presentation retires the create seat on dismiss")
    }
    /// The source the composition checks read, from the worktree root the
    /// checks binary runs in, falling back to this file's own directory.
    private static func sourceFile(_ relative: String) -> String? {
        let fm = FileManager.default
        let fromCwd = fm.currentDirectoryPath + "/" + relative
        if fm.fileExists(atPath: fromCwd) { return fromCwd }
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent().path
        for _ in 0..<4 {
            let candidate = dir + "/" + relative
            if fm.fileExists(atPath: candidate) { return candidate }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
