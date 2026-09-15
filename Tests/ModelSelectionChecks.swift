import Foundation

// PARITY-2A: model selection with reasoning effort, driven through the
// production gate, request builder and reasoning policy with a delayed fake
// transport the tests hold parked between the request and the response.
//
// What the checks close:
//
//   * the wire shape - an explicit effort travels verbatim, a nil or empty
//     effort is omitted entirely, never sent as an empty string;
//   * the accepted selection comes from the server response, not the request -
//     the test requests one effort, the response returns a normalized one, and
//     the stored selection must be the normalized value;
//   * the accepted-response contract - onAccepted receives the full response
//     and the store extracts "selected" exactly once (a gate that pre-extracts
//     it clobbers the stored selection to null);
//   * overlap - a superseded success or error settles stale, never releases
//     the newer request's busy state and never lands state; the newer
//     response may land first;
//   * a superseded request's deferred catalog refresh is dropped while its
//     accepted selection stands;
//   * a failed catalog refresh keeps the selection with its own outcome,
//     distinct from a rejected selection;
//   * session identity - a session switch, A -> B -> A (session-id equality
//     alone must not revive the old request), a disconnect generation rotation
//     and a carrier attempt rotation each invalidate the in-flight request,
//     dropping its seat and busy state before the old response can land;
//   * the production store path - the real PocketStore driven with a parked
//     HarnessAPI transport: a session switch, a disconnect and a same-session
//     supersede each release the busy state immediately, a stale response
//     writes no error and no state, and a superseded selection's late list
//     refresh (success or failure) never overwrites the newer selection's
//     sessions or error;
//   * the catalog policy - no reasoning means no selector, empty efforts mean
//     no selector, no advertised default means a "Default" row, custom and
//     unknown effort ids are preserved verbatim.
//
// The transport is the only fake; the gate, the request builder, the
// reasoning policy and the carrier identity are the production code from
// PocketDSH/ModelSelection.swift and RemoteStreamConnection.swift.

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
    func selectModelRequest(_ index: Int) -> JSON { parked[index].args["request"] ?? .null }
    /// The parked calls of one method, in arrival order.
    func calls(_ method: String) -> [ParkedCall] { parked.filter { $0.method == method } }
}

/// PocketStore.selectModel's wiring, on the production gate: the busy flag,
/// the stored selection and catalog, the session-scoped acceptance guard, and
/// the outcome -> error mapping the store applies. The store's onAccepted
/// contract is mirrored exactly: the callback receives the full accepted
/// response and extracts "selected" once.
@MainActor
final class SelectionHarness {
    let gate = ModelSelectionGate()
    let transport = DeferredTransport()
    var busy = false
    /// The store's accepted selection: "selected" of the accepted response.
    var model: JSON = .null
    /// The store's catalog.
    var catalog: JSON = .null
    var acceptedCount = 0
    var catalogCount = 0
    var error: String?
    private var lastError: Error?
    /// The store's seat: the selection the store last started. Post-response
    /// effects belong only to the operation holding it.
    private(set) var activeSelection: ModelSelectionGate.Operation?

    // The live identity PocketStore keeps; the tests rotate these parts.
    var session: String?
    var endpoint = "https://dsn.example"
    var generation = UUID()
    var epoch = UUID()
    var acceptsAttempt: (RemoteStreamConnection.RefreshToken?) -> Bool = { _ in true }
    var currentAttempt: RemoteStreamConnection.RefreshToken?

    func isLive(_ op: ModelSelectionGate.Operation) -> Bool {
        guard let session, session == op.sessionID else { return false }
        return op.endpoint == endpoint && op.generation == generation && op.epoch == epoch && acceptsAttempt(op.attempt)
    }

    /// PocketStore.selectModel, on the production gate: the store creates the
    /// operation, takes the seat, and hands the same instance to the gate.
    func select(_ provider: String, _ model: String, effort: String? = nil, sessionID: String) async -> (outcome: ModelSelectionGate.Outcome, operation: ModelSelectionGate.Operation) {
        let id = sessionID
        let op = ModelSelectionGate.Operation(sessionID: id, endpoint: endpoint, generation: generation, epoch: epoch, attempt: currentAttempt)
        activeSelection = op
        let result = await gate.select(op, provider: provider, model: model, effort: effort,
                                       onBusy: { [weak self] in self?.busy = $0 },
                                       rpc: { [weak self] method, args in
                                           do { return try await self?.transport.rpc(method, args: args) ?? .null }
                                           catch { self?.lastError = error; throw error }
                                       },
                                       live: { [weak self] op in self?.isLive(op) ?? false },
                                       onAccepted: { [weak self] value in
                                           guard let self, self.session == id else { return }
                                           self.acceptedCount += 1
                                           self.model = value["selected"]
                                       },
                                       onCatalog: { [weak self] value in
                                           guard let self, self.session == id else { return }
                                           self.catalogCount += 1
                                           self.catalog = value
                                       })
        switch result.outcome {
        case .applied, .catalogFailed:
            guard activeSelection === op else { break }
            error = result.outcome == .applied ? nil : "Model selected, but the catalog did not refresh."
        case .rejected:
            guard activeSelection === op else { break }
            error = "Could not confirm the selected model: " + (lastError?.localizedDescription ?? "request failed")
        default: break
        }
        return result
    }

    /// PocketStore.select's identity step: a real session switch rotates the
    /// epoch and drops the in-flight selection's seat and busy state at once.
    func switchSession(_ id: String?) {
        if session != id {
            epoch = UUID()
            gate.invalidateCurrent()
            activeSelection = nil
        }
        session = id
    }

    /// PocketStore.disconnect's identity step: the generation rotates and the
    /// in-flight selection is dropped at once, before the old response can land.
    func disconnect() {
        generation = UUID()
        epoch = UUID()
        gate.invalidateCurrent()
        activeSelection = nil
    }
}

@main struct ModelSelectionChecks {
    // The catalog rows, shaped exactly as the Host's session/modelCatalog
    // serves them.
    static let modelPlain = JSON.object(["id": .string("m-plain"), "name": .string("Plain")])
    static let modelDefaulted = JSON.object([
        "id": .string("m-defaulted"), "name": .string("Defaulted"),
        "reasoning": .object([
            "efforts": .array([
                .object(["id": .string("xhigh"), "name": .string("X High")]),
                .object(["id": .string("high"), "name": .string("High")]),
                .object(["id": .string("low"), "name": .string("Low")])
            ]),
            "defaultEffort": .string("high")
        ])
    ])
    static let modelUndefaulted = JSON.object([
        "id": .string("m-undefaulted"), "name": .string("Undefaulted"),
        "reasoning": .object([
            "efforts": .array([
                .object(["id": .string("minimal"), "name": .string("Minimal")]),
                .object(["id": .string("max"), "name": .string("Max")])
            ])
        ])
    ])
    static let modelCustom = JSON.object([
        "id": .string("m-custom"), "name": .string("Custom"),
        "reasoning": .object([
            "efforts": .array([
                .object(["id": .string("turbo-9"), "name": .string("Turbo 9")])
            ])
        ])
    ])
    static let modelEmptyEfforts = JSON.object([
        "id": .string("m-empty"), "name": .string("Empty"),
        "reasoning": .object(["efforts": .array([])])
    ])

    /// One catalog, as session/modelCatalog returns it; the marker
    /// distinguishes a refreshed copy from the original.
    static func catalog(_ marker: String) -> JSON {
        .object([
            "default": .object(["provider": .string("provA"), "model": .string("m-plain")]),
            "groups": .array([
                .object([
                    "id": .string("provA"), "name": .string("A"),
                    "models": .array([modelPlain, modelDefaulted, modelUndefaulted, modelEmptyEfforts])
                ]),
                .object([
                    "id": .string("provB"), "name": .string("B"),
                    "models": .array([modelCustom])
                ])
            ]),
            "failures": .array([.string(marker)])
        ])
    }

    static func selection(_ provider: String, _ model: String, effort: String?) -> JSON {
        var sel: [String: JSON] = ["provider": .string(provider), "model": .string(model)]
        if let effort { sel["reasoningEffort"] = .string(effort) }
        return .object(sel)
    }

    static func selected(_ provider: String, _ model: String, effort: String?) -> JSON {
        .object(["selected": selection(provider, model, effort: effort)])
    }

    /// Poll a condition until it holds, so the parked transport and the gate
    /// interleave deterministically instead of racing on a fixed delay.
    @MainActor
    static func spin(_ reached: () -> Bool) async {
        let deadline = Date().addingTimeInterval(20)
        while !reached() {
            assert(Date() < deadline, "the selection never reached the state the test expected")
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do {
            try await requestShape()
            try await catalogPolicy()
            try await effectiveEffortPolicy()
            try await acceptedSelectionComesFromResponse()
            try await catalogFailureKeepsSelection()
            try await rejectionKeepsAcceptedSelection()
            try await supersededSuccessIsStale()
            try await supersededErrorIsStale()
            try await deferredCatalogOfSupersededOpIsDropped()
            try await newerResponseFirstStillStalesOlder()
            try await sessionSwitchStalesInFlight()
            try await aToBToADoesNotRevive()
            try await disconnectGenerationStalesInFlight()
            try await carrierAttemptStalesInFlight()
            try await prodSwitchSessionReleasesSeatImmediately()
            try await prodDisconnectReleasesSeatAndReconnectAdmits()
            try await prodSameSessionSupersedeKeepsNewerState()
            try await prodLateRefreshSuccessNeverOverwrites()
            try await prodLateRefreshFailureNeverOverwrites()
            try await prodStaleAppliedNeverFollowsLiveConversation()
            print("PASS: model selection keeps effort semantics, response authority and operation identity")
            exit(0)
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    // (1) The wire shape: an explicit effort travels verbatim; a nil or empty
    // effort omits the field entirely - never an empty string on the wire.
    @MainActor
    static func requestShape() async throws {
        func request(_ effort: String?) -> JSON {
            selectModelRequest(provider: "provA", model: "m-defaulted", effort: effort, sessionID: "s1")["request"] ?? .null
        }
        let explicit = request("xhigh")
        assert(explicit["sessionId"].string == "s1" && explicit["provider"].string == "provA"
               && explicit["model"].string == "m-defaulted"
               && explicit["reasoningEffort"].string == "xhigh",
               "the request carries the session, provider, model and the exact effort")
        assert(request(nil)["reasoningEffort"] == .null, "a nil effort omits the field, it is not sent empty")
        assert(request("")["reasoningEffort"] == .null, "an empty effort omits the field, it is not sent empty")
        print("PASS: the request sends the effort verbatim and omits it for the provider default")
    }

    // (2) The catalog policy: no reasoning means no selector, empty efforts
    // mean no selector at all, no advertised default means a "Default" row,
    // and custom effort ids and names are preserved verbatim.
    @MainActor
    static func catalogPolicy() async throws {
        assert(reasoning(for: modelPlain) == nil, "a model without a reasoning block advertises none")
        assert(effortChoices(for: modelPlain).isEmpty, "no reasoning means no effort selector")
        assert(reasoning(for: modelEmptyEfforts) == nil, "empty efforts mean no selector, not a fabricated one")
        assert(effortChoices(for: modelEmptyEfforts).isEmpty, "empty efforts mean no effort selector")
        let defaulted = reasoning(for: modelDefaulted)!
        assert(defaulted.efforts.map { $0.id } == ["xhigh", "high", "low"] && defaulted.defaultEffort == "high",
               "the advertised efforts and default come from the catalog")
        assert(effortChoices(for: modelDefaulted).map { $0.effortID } == ["xhigh", "high", "low"],
               "a model with an advertised default lists only its efforts, no separate Default row")
        let undefaulted = effortChoices(for: modelUndefaulted)
        assert(undefaulted.map { $0.effortID } == [nil, "minimal", "max"] && undefaulted[0].label == "Default",
               "no advertised default means a Default row ahead of the explicit efforts")
        let custom = effortChoices(for: modelCustom)
        assert(custom.map { $0.effortID } == [nil, "turbo-9"] && custom[1].label == "Turbo 9",
               "custom effort ids and names are preserved verbatim")
        assert(catalogModel(provider: "provA", model: "m-defaulted", catalog: catalog("x"))?.object["id"]?.string == "m-defaulted",
               "the catalog lookup finds the row by provider and model")
        assert(catalogModel(provider: "provB", model: "m-defaulted", catalog: catalog("x")) == nil,
               "a wrong provider does not match the row")
        print("PASS: the catalog policy keeps the selector exactly as advertised")
    }

    // (3) The effective effort of a selection: the accepted id when the Host
    // returned one, else the advertised default; unknown ids stay verbatim;
    // a model without reasoning shows no effort at all.
    @MainActor
    static func effectiveEffortPolicy() async throws {
        let cat = catalog("x")
        assert(effectiveEffortID(selection: selection("provA", "m-defaulted", effort: "xhigh"), model: modelDefaulted) == "xhigh",
               "an accepted custom effort wins over the advertised default")
        assert(effectiveEffortID(selection: selection("provA", "m-defaulted", effort: nil), model: modelDefaulted) == "high",
               "no accepted effort falls back to the advertised default")
        assert(effectiveEffortID(selection: selection("provA", "m-undefaulted", effort: nil), model: modelUndefaulted) == nil,
               "no accepted effort and no advertised default means the provider default")
        assert(effectiveEffortID(selection: selection("provA", "m-defaulted", effort: "mystery"), model: modelDefaulted) == "mystery",
               "an unknown accepted effort id is preserved, not dropped")
        assert(effectiveEffortID(selection: selection("provA", "m-plain", effort: "high"), model: modelPlain) == nil,
               "a model without reasoning resolves no effort")
        assert(effectiveEffortLabel(selection: selection("provA", "m-defaulted", effort: "xhigh"), catalog: cat) == "X High",
               "the label comes from the catalog row")
        assert(effectiveEffortLabel(selection: selection("provA", "m-defaulted", effort: nil), catalog: cat) == "High",
               "the default effort renders its catalog name")
        assert(effectiveEffortLabel(selection: selection("provA", "m-undefaulted", effort: nil), catalog: cat) == "Default",
               "the provider default renders as Default")
        assert(effectiveEffortLabel(selection: selection("provA", "m-defaulted", effort: "mystery"), catalog: cat) == "mystery",
               "an unknown accepted id renders verbatim")
        assert(effectiveEffortLabel(selection: selection("provA", "m-plain", effort: nil), catalog: cat) == nil,
               "no reasoning means no effort in the model label")
        assert(effectiveEffortLabel(selection: selection("provB", "m-defaulted", effort: nil), catalog: cat) == nil,
               "a selection from another provider matches no row")
        print("PASS: the effective effort keeps accepted ids verbatim and falls back to the catalog")
    }

    // (4) The accepted selection comes from the server response, not the
    // request: the test asks for one effort, the response normalizes it, and
    // the stored selection must be the normalized value. onAccepted receives
    // the full accepted response and the store extracts "selected" once - a
    // gate that pre-extracts it stores null.
    @MainActor
    static func acceptedSelectionComesFromResponse() async throws {
        let harness = SelectionHarness()
        harness.session = "s1"
        let op = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "xhigh", sessionID: "s1") }
        await spin { harness.transport.parked.count == 1 }
        assert(harness.transport.selectModelRequest(0)["reasoningEffort"].string == "xhigh",
               "the wire carries the requested effort, not the normalized one")
        harness.transport.parked[0].respond(selected("provA", "m-defaulted", effort: "high"))
        await spin { harness.transport.parked.count == 2 }
        harness.transport.parked[1].respond(catalog("fresh"))
        let result = await op.value
        assert(result.outcome == .applied, "the selection applies and the catalog refreshes")
        assert(harness.model != .null, "the accepted selection is not clobbered to null")
        assert(harness.model["provider"].string == "provA" && harness.model["model"].string == "m-defaulted"
               && harness.model["reasoningEffort"].string == "high",
               "the stored selection is the accepted response, with its normalized effort")
        assert(harness.catalog["failures"].array.first?.string == "fresh", "the refreshed catalog is the one the Host returned")
        assert(!harness.busy && harness.error == nil, "the busy state releases and no error remains")
        print("PASS: the accepted selection comes from the response, normalized by the Host")
    }

    // (5) A failed catalog refresh keeps the accepted selection with its own
    // outcome, distinct from a rejected selection.
    @MainActor
    static func catalogFailureKeepsSelection() async throws {
        let harness = SelectionHarness()
        harness.session = "s1"
        let op = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "low", sessionID: "s1") }
        await spin { harness.transport.parked.count == 1 }
        harness.transport.parked[0].respond(selected("provA", "m-defaulted", effort: "low"))
        await spin { harness.transport.parked.count == 2 }
        harness.transport.parked[1].fail(HarnessError(message: "the catalog refresh refused"))
        let result = await op.value
        assert(result.outcome == .catalogFailed, "a failed catalog refresh is its own outcome")
        assert(harness.model["model"].string == "m-defaulted" && harness.model["reasoningEffort"].string == "low",
               "the accepted selection survives the catalog failure")
        assert(harness.error == "Model selected, but the catalog did not refresh.",
               "the user sees the catalog failure, not a rejection")
        assert(!harness.busy, "the busy state releases")
        print("PASS: a failed catalog refresh keeps the selection with its own outcome")
    }

    // (6) A rejected selection preserves the previously accepted selection:
    // nothing is applied, the stored model is untouched, and the error says
    // the selection could not be confirmed.
    @MainActor
    static func rejectionKeepsAcceptedSelection() async throws {
        let harness = SelectionHarness()
        harness.session = "s1"
        harness.model = selection("provA", "m-defaulted", effort: "high")
        let op = Task { @MainActor in await harness.select("provB", "m-custom", effort: "turbo-9", sessionID: "s1") }
        await spin { harness.transport.parked.count == 1 }
        harness.transport.parked[0].fail(HarnessError(message: "the Host rejected the effort"))
        let result = await op.value
        assert(result.outcome == .rejected, "a rejected selection is its own outcome")
        assert(harness.acceptedCount == 0, "a rejected selection applies nothing")
        assert(harness.model == selection("provA", "m-defaulted", effort: "high"),
               "the previously accepted selection survives the rejection")
        assert(harness.error == "Could not confirm the selected model: the Host rejected the effort",
               "the rejection surfaces the transport's error")
        assert(!harness.busy, "the busy state releases")
        print("PASS: a rejected selection preserves the accepted one")
    }

    // (7) Overlap: the second tap supersedes the first. The first response,
    // held back and then delivered, settles stale - it lands no state and
    // does not release the busy state the second request owns. The second
    // request then applies normally.
    @MainActor
    static func supersededSuccessIsStale() async throws {
        let harness = SelectionHarness()
        harness.session = "s1"
        let first = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "xhigh", sessionID: "s1") }
        await spin { harness.transport.parked.count == 1 }
        let second = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "low", sessionID: "s1") }
        await spin { harness.transport.parked.count == 2 }
        assert(harness.busy, "the busy state is held while a selection is in flight")
        harness.transport.parked[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        let firstResult = await first.value
        assert(firstResult.outcome == .stale, "the superseded success settles stale")
        assert(harness.acceptedCount == 0, "the superseded response lands no selection")
        assert(harness.busy, "the superseded response does not release the newer request's busy state")
        assert(harness.model == .null && harness.error == nil, "the superseded response touches no state")
        harness.transport.parked[1].respond(selected("provA", "m-defaulted", effort: "low"))
        await spin { harness.transport.parked.count == 3 }
        harness.transport.parked[2].respond(catalog("fresh"))
        let secondResult = await second.value
        assert(secondResult.outcome == .applied, "the newer request applies normally")
        assert(harness.model["model"].string == "m-defaulted" && harness.model["reasoningEffort"].string == "low",
               "the newer request's selection is the one stored")
        assert(harness.acceptedCount == 1 && !harness.busy && harness.error == nil,
               "exactly one acceptance, the busy state releases")
        print("PASS: a superseded success stays stale and keeps the newer request's busy state")
    }

    // (8) Overlap with an error: the first request's failure, delivered after
    // the supersede, settles stale - it is not reported as the error of a
    // selection the user no longer asked for.
    @MainActor
    static func supersededErrorIsStale() async throws {
        let harness = SelectionHarness()
        harness.session = "s1"
        let first = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "xhigh", sessionID: "s1") }
        await spin { harness.transport.parked.count == 1 }
        let second = Task { @MainActor in await harness.select("provA", "m-undefaulted", effort: "max", sessionID: "s1") }
        await spin { harness.transport.parked.count == 2 }
        harness.transport.parked[0].fail(HarnessError(message: "the first request died"))
        let firstResult = await first.value
        assert(firstResult.outcome == .stale, "the superseded failure settles stale")
        assert(harness.error == nil, "the superseded failure is not reported")
        assert(harness.busy, "the superseded failure does not release the newer request's busy state")
        harness.transport.parked[1].respond(selected("provA", "m-undefaulted", effort: "max"))
        await spin { harness.transport.parked.count == 3 }
        harness.transport.parked[2].respond(catalog("fresh"))
        let secondResult = await second.value
        assert(secondResult.outcome == .applied, "the newer request applies normally")
        assert(harness.model["model"].string == "m-undefaulted" && !harness.busy, "the newer selection is stored, the busy state releases")
        print("PASS: a superseded failure stays stale and is not reported")
    }

    // (9) The first request's catalog refresh, held back across the supersede,
    // is dropped - its catalog is not published - while its accepted
    // selection stands: the selection boundary and the catalog boundary are
    // separate.
    @MainActor
    static func deferredCatalogOfSupersededOpIsDropped() async throws {
        let harness = SelectionHarness()
        harness.session = "s1"
        let first = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "xhigh", sessionID: "s1") }
        await spin { harness.transport.parked.count == 1 }
        harness.transport.parked[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        await spin { harness.transport.parked.count == 2 }
        // The first request's catalog is parked; the second request supersedes.
        let second = Task { @MainActor in await harness.select("provA", "m-undefaulted", effort: "max", sessionID: "s1") }
        await spin { harness.transport.parked.count == 3 }
        harness.transport.parked[1].respond(catalog("stale"))
        let firstResult = await first.value
        assert(firstResult.outcome == .stale, "the superseded request settles stale")
        assert(harness.catalogCount == 0, "the deferred catalog refresh is not published")
        assert(harness.model["model"].string == "m-defaulted" && harness.model["reasoningEffort"].string == "xhigh",
               "the first request's accepted selection stands")
        assert(harness.busy, "the newer request still owns the busy state")
        harness.transport.parked[2].respond(selected("provA", "m-undefaulted", effort: "max"))
        await spin { harness.transport.parked.count == 4 }
        harness.transport.parked[3].respond(catalog("fresh"))
        let secondResult = await second.value
        assert(secondResult.outcome == .applied, "the newer request applies normally")
        assert(harness.catalog["failures"].array.first?.string == "fresh" && harness.catalogCount == 1,
               "exactly one catalog is published: the live request's")
        assert(harness.model["model"].string == "m-undefaulted" && !harness.busy, "the newer selection is stored, the busy state releases")
        print("PASS: a superseded request's deferred catalog is dropped, its selection stands")
    }

    // (10) Both completion orders: the newer request's response may land
    // first, while the older request is still in flight. The older response,
    // delivered after, settles stale - including the case where no operation
    // is active by then.
    @MainActor
    static func newerResponseFirstStillStalesOlder() async throws {
        let harness = SelectionHarness()
        harness.session = "s1"
        let first = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "xhigh", sessionID: "s1") }
        await spin { harness.transport.parked.count == 1 }
        let second = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "low", sessionID: "s1") }
        await spin { harness.transport.parked.count == 2 }
        harness.transport.parked[1].respond(selected("provA", "m-defaulted", effort: "low"))
        await spin { harness.transport.parked.count == 3 }
        harness.transport.parked[2].respond(catalog("fresh"))
        let secondResult = await second.value
        assert(secondResult.outcome == .applied, "the newer request applies while the older is still in flight")
        assert(harness.model["reasoningEffort"].string == "low", "the newer selection is stored")
        harness.transport.parked[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        let firstResult = await first.value
        assert(firstResult.outcome == .stale, "the older response settles stale after the newer applied")
        assert(harness.model["reasoningEffort"].string == "low", "the late older response does not clobber the newer selection")
        assert(harness.acceptedCount == 1 && !harness.busy && harness.error == nil,
               "one acceptance, the busy state released once")
        print("PASS: the newer response may land first; the older one still settles stale")
    }

    // (11) A session switch while the request is in flight: the response
    // arrives for the session the user left - the session and the epoch both
    // moved, so the response settles stale and nothing is landed.
    @MainActor
    static func sessionSwitchStalesInFlight() async throws {
        let harness = SelectionHarness()
        harness.session = "sA"
        let op = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "xhigh", sessionID: "sA") }
        await spin { harness.transport.parked.count == 1 }
        harness.switchSession("sB")
        assert(!harness.busy, "the switch releases the busy state before the old response lands")
        harness.transport.parked[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        let result = await op.value
        assert(result.outcome == .stale, "a session switch stales the in-flight selection")
        assert(harness.acceptedCount == 0 && harness.model == .null, "the late response lands nothing")
        assert(!harness.busy, "the busy state releases with the stale operation")
        print("PASS: a session switch stales the in-flight selection")
    }

    // (12) A -> B -> A: the session id matches the original request again,
    // but the epoch rotated on each switch, so the id equality alone must
    // not revive the old request.
    @MainActor
    static func aToBToADoesNotRevive() async throws {
        let harness = SelectionHarness()
        harness.session = "sA"
        let originalEpoch = harness.epoch
        let op = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "xhigh", sessionID: "sA") }
        await spin { harness.transport.parked.count == 1 }
        harness.switchSession("sB")
        harness.switchSession("sA")
        assert(!harness.busy, "both switches released the busy state before any response")
        assert(harness.session == "sA" && harness.epoch != originalEpoch,
               "the session id matches again, the epoch does not")
        harness.transport.parked[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        let result = await op.value
        assert(result.outcome == .stale, "A -> B -> A does not revive the original request on session-id equality")
        assert(harness.acceptedCount == 0 && harness.model == .null, "the late response lands nothing")
        assert(!harness.busy, "the busy state releases with the stale operation")
        print("PASS: A -> B -> A settles stale; the epoch, not the session id, revives a request")
    }

    // (13) A disconnect rotates the generation; the in-flight response
    // belongs to the old connection and settles stale. The reconnected
    // session admits new selections again.
    @MainActor
    static func disconnectGenerationStalesInFlight() async throws {
        let harness = SelectionHarness()
        harness.session = "s1"
        let op = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "xhigh", sessionID: "s1") }
        await spin { harness.transport.parked.count == 1 }
        harness.disconnect()
        assert(!harness.busy, "the disconnect releases the busy state before the old response lands")
        harness.transport.parked[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        let result = await op.value
        assert(result.outcome == .stale, "a disconnect stales the in-flight selection")
        assert(harness.acceptedCount == 0 && harness.model == .null, "the late response lands nothing")
        harness.generation = UUID()
        let again = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "low", sessionID: "s1") }
        await spin { harness.transport.parked.count == 2 }
        harness.transport.parked[1].respond(selected("provA", "m-defaulted", effort: "low"))
        await spin { harness.transport.parked.count == 3 }
        harness.transport.parked[2].respond(catalog("fresh"))
        let againResult = await again.value
        assert(againResult.outcome == .applied, "the reconnected session admits new selections")
        assert(harness.model["reasoningEffort"].string == "low" && !harness.busy, "the new selection is stored, the busy state releases")
        print("PASS: a disconnect stales the old request; the reconnect admits new ones")
    }

    // (14) The carrier attempt: a request captured on one socket attempt is
    // not admitted after the carrier reconnects on a new attempt - the real
    // RemoteStreamConnection decides. A request captured before any attempt
    // (no token) is admitted: a nil token belongs to the connection its
    // caller holds.
    @MainActor
    static func carrierAttemptStalesInFlight() async throws {
        let harness = SelectionHarness()
        let carrier = RemoteStreamConnection()
        harness.acceptsAttempt = { carrier.accepts($0) }
        harness.session = "s1"
        carrier.beginAttempt(index: 1)
        harness.currentAttempt = carrier.currentRefreshToken()
        let op = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "xhigh", sessionID: "s1") }
        await spin { harness.transport.parked.count == 1 }
        carrier.beginAttempt(index: 2)
        harness.transport.parked[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        let result = await op.value
        assert(result.outcome == .stale, "a carrier reconnect stales the old attempt's selection")
        assert(harness.acceptedCount == 0 && harness.model == .null, "the late response lands nothing")
        harness.currentAttempt = carrier.currentRefreshToken()
        let again = Task { @MainActor in await harness.select("provA", "m-defaulted", effort: "low", sessionID: "s1") }
        await spin { harness.transport.parked.count == 2 }
        harness.transport.parked[1].respond(selected("provA", "m-defaulted", effort: "low"))
        await spin { harness.transport.parked.count == 3 }
        harness.transport.parked[2].respond(catalog("fresh"))
        let againResult = await again.value
        assert(againResult.outcome == .applied, "the live attempt's selection applies")
        assert(!harness.busy, "the busy state releases")
        carrier.stop()
        harness.currentAttempt = carrier.currentRefreshToken()
        assert(harness.currentAttempt == nil, "a stopped carrier mints no token")
        let unbound = Task { @MainActor in await harness.select("provA", "m-undefaulted", effort: "max", sessionID: "s1") }
        await spin { harness.transport.parked.count == 4 }
        harness.transport.parked[3].respond(selected("provA", "m-undefaulted", effort: "max"))
        await spin { harness.transport.parked.count == 5 }
        harness.transport.parked[4].respond(catalog("fresh2"))
        let unboundResult = await unbound.value
        assert(unboundResult.outcome == .applied, "a nil-token selection is admitted by its own caller's identity")
        print("PASS: the carrier attempt identity stales old selections and admits new ones")
    }

    // MARK: - The production store, on a parked transport
    //
    // The same liveness checks through the real PocketStore: the store's own
    // selectModel, refresh, select and disconnect code run unchanged, with
    // only the wire faked. FakeAPI subclasses the production HarnessAPI on
    // the parked transport, so request and response travel the production
    // rpc path.

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

    /// A session/list response with exactly these ids.
    @MainActor
    static func list(_ ids: [String]) -> JSON {
        .object(["items": .array(ids.map { .object(["sessionId": .string($0), "cwd": .string("/w"), "updatedAt": .number(1), "running": .bool(false)]) })])
    }

    // (15) Production: a session switch drops the in-flight selection's seat
    // and busy state immediately - the controls are unblocked before the old
    // response can land - and the old response settles stale and writes
    // nothing. A -> B -> A included.
    @MainActor
    static func prodSwitchSessionReleasesSeatImmediately() async throws {
        let api = FakeAPI()
        let store = PocketStore()
        wire(store, api, sessions: ["sA", "sB"])
        await store.select("sA")
        let first = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "xhigh") }
        await spin { api.transport.calls("session/selectModel").count == 1 }
        assert(store.selectingModel, "the in-flight selection holds the busy state")
        // The switch: seat and busy state die at once, before the response.
        await store.select("sB")
        assert(!store.selectingModel, "the switch releases the busy state before the old response lands")
        assert(store.activeSelection == nil && store.selection.active == nil, "the in-flight selection loses its seat")
        api.transport.calls("session/selectModel")[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        await first.value
        assert(store.model == .null, "the stale response writes no model")
        assert(store.error == nil, "the stale response writes no error")
        assert(api.transport.calls("session/modelCatalog").count == 0, "the stale response refreshes no catalog")
        assert(api.transport.calls("session/list").count == 0, "the stale selection refreshes no list")
        // A -> B -> A: back on the original session, a new selection applies.
        await store.select("sA")
        assert(!store.selectingModel, "back on A the controls stay unblocked")
        let back = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "low") }
        await spin { api.transport.calls("session/selectModel").count == 2 }
        api.transport.calls("session/selectModel")[1].respond(selected("provA", "m-defaulted", effort: "low"))
        await spin { api.transport.calls("session/modelCatalog").count == 1 }
        api.transport.calls("session/modelCatalog")[0].respond(catalog("fresh"))
        await spin { api.transport.calls("session/list").count == 1 }
        api.transport.calls("session/list")[0].respond(list(["sA", "sB"]))
        await back.value
        assert(store.model["reasoningEffort"].string == "low", "the back-on-A selection applies")
        assert(store.sessions.count == 2, "its refresh applied the list")
        assert(!store.selectingModel, "the busy state releases")
        print("PASS: production - a session switch drops the in-flight selection at once")
    }

    // (16) Production: a disconnect drops the seat and busy state at once;
    // the dead connection's response settles stale and writes nothing; the
    // reconnected store admits new selections again.
    @MainActor
    static func prodDisconnectReleasesSeatAndReconnectAdmits() async throws {
        let api = FakeAPI()
        let store = PocketStore()
        wire(store, api, sessions: ["sA"])
        await store.select("sA")
        let first = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "xhigh") }
        await spin { api.transport.calls("session/selectModel").count == 1 }
        assert(store.selectingModel, "the in-flight selection holds the busy state")
        store.disconnect()
        assert(!store.selectingModel, "the disconnect releases the busy state before the old response lands")
        assert(store.activeSelection == nil && store.selection.active == nil, "the in-flight selection loses its seat")
        assert(store.api == nil && !store.connected, "the dead connection is gone")
        api.transport.calls("session/selectModel")[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        await first.value
        assert(store.model == .null, "the dead connection's response writes no model")
        assert(store.error == nil, "the dead connection's response writes no error")
        assert(api.transport.calls("session/list").count == 0, "the dead selection refreshes no list")
        // Reconnect: a fresh api on the rotated generation.
        let fresh = FakeAPI()
        wire(store, fresh, sessions: ["sA"])
        await store.select("sA")
        let again = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "low") }
        await spin { fresh.transport.calls("session/selectModel").count == 1 }
        fresh.transport.calls("session/selectModel")[0].respond(selected("provA", "m-defaulted", effort: "low"))
        await spin { fresh.transport.calls("session/modelCatalog").count == 1 }
        fresh.transport.calls("session/modelCatalog")[0].respond(catalog("fresh"))
        await spin { fresh.transport.calls("session/list").count == 1 }
        fresh.transport.calls("session/list")[0].respond(list(["sA"]))
        await again.value
        assert(store.model["reasoningEffort"].string == "low", "the reconnected session admits new selections")
        assert(!store.selectingModel, "the busy state releases")
        print("PASS: production - a disconnect drops the seat at once; the reconnect admits new selections")
    }

    // (17) Production, same session: a newer selection supersedes the
    // in-flight one. The newer rejection is the reported error; the older
    // response lands after, stale, and writes nothing.
    @MainActor
    static func prodSameSessionSupersedeKeepsNewerState() async throws {
        let api = FakeAPI()
        let store = PocketStore()
        wire(store, api, sessions: ["sA"])
        await store.select("sA")
        let first = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "xhigh") }
        await spin { api.transport.calls("session/selectModel").count == 1 }
        let second = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "low") }
        await spin { api.transport.calls("session/selectModel").count == 2 }
        api.transport.calls("session/selectModel")[1].fail(HarnessError(message: "the Host rejected the effort"))
        await second.value
        assert(store.error == "Could not confirm the selected model: the Host rejected the effort", "the newer rejection is reported")
        api.transport.calls("session/selectModel")[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        await first.value
        assert(store.error == "Could not confirm the selected model: the Host rejected the effort", "the stale response keeps the newer error")
        assert(store.model == .null, "the stale response writes no model")
        assert(api.transport.calls("session/modelCatalog").count == 0, "the stale response refreshes no catalog")
        assert(api.transport.calls("session/list").count == 0, "the stale selection refreshes no list")
        print("PASS: production - a stale same-session response keeps the newer selection's state")
    }

    // (18) Production: a superseded selection's late list refresh - even a
    // successful one - never overwrites the sessions the newer selection
    // published.
    @MainActor
    static func prodLateRefreshSuccessNeverOverwrites() async throws {
        let api = FakeAPI()
        let store = PocketStore()
        wire(store, api, sessions: ["sA"])
        await store.select("sA")
        let first = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "xhigh") }
        await spin { api.transport.calls("session/selectModel").count == 1 }
        api.transport.calls("session/selectModel")[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        await spin { api.transport.calls("session/modelCatalog").count == 1 }
        api.transport.calls("session/modelCatalog")[0].respond(catalog("stale"))
        await spin { api.transport.calls("session/list").count == 1 }
        // The first selection's refresh is in flight; the newer one starts.
        let second = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "low") }
        await spin { api.transport.calls("session/selectModel").count == 2 }
        api.transport.calls("session/selectModel")[1].respond(selected("provA", "m-defaulted", effort: "low"))
        await spin { api.transport.calls("session/modelCatalog").count == 2 }
        api.transport.calls("session/modelCatalog")[1].respond(catalog("fresh"))
        await spin { api.transport.calls("session/list").count == 2 }
        api.transport.calls("session/list")[1].respond(list(["sA", "sB"]))
        await second.value
        assert(store.sessions.count == 2 && store.sessions[1].id == "sB", "the newer selection's refresh applied")
        api.transport.calls("session/list")[0].respond(list(["sA"]))
        await first.value
        assert(store.sessions.count == 2 && store.sessions[1].id == "sB", "the late refresh did not overwrite the newer list")
        assert(!store.selectingModel, "the busy state releases")
        print("PASS: production - a superseded selection's late refresh keeps off the sessions")
    }

    // (19) Production: a superseded selection's late list refresh - a
    // failure - never overwrites the error the newer rejection reported,
    // and the first selection's accepted model stands.
    @MainActor
    static func prodLateRefreshFailureNeverOverwrites() async throws {
        let api = FakeAPI()
        let store = PocketStore()
        wire(store, api, sessions: ["sA"])
        await store.select("sA")
        let first = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "xhigh") }
        await spin { api.transport.calls("session/selectModel").count == 1 }
        api.transport.calls("session/selectModel")[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        await spin { api.transport.calls("session/modelCatalog").count == 1 }
        api.transport.calls("session/modelCatalog")[0].respond(catalog("stale"))
        await spin { api.transport.calls("session/list").count == 1 }
        let second = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "low") }
        await spin { api.transport.calls("session/selectModel").count == 2 }
        api.transport.calls("session/selectModel")[1].fail(HarnessError(message: "the Host rejected the effort"))
        await second.value
        assert(store.error == "Could not confirm the selected model: the Host rejected the effort", "the newer rejection is reported")
        api.transport.calls("session/list")[0].fail(HarnessError(message: "the list expired"))
        await first.value
        assert(store.error == "Could not confirm the selected model: the Host rejected the effort", "the late refresh failure keeps the newer error")
        assert(store.model["reasoningEffort"].string == "xhigh", "the first selection's accepted model stands")
        print("PASS: production - a superseded selection's late refresh failure keeps off the error")
    }

    // (20) Production: ownership is re-checked after every post-gate await.
    // A .applied selection whose list refresh parked behind a same-session
    // supersedure must not follow or reset the live conversation when the
    // list finally resolves. The supersedure rotated nothing the liveness
    // check can see - same session, same epoch, same generation, attempt
    // still accepted - so only the fresh activeSelection re-check catches it.
    @MainActor
    static func prodStaleAppliedNeverFollowsLiveConversation() async throws {
        let api = FakeAPI()
        let store = PocketStore()
        var follows: [String?] = []
        store.conversationFollowObservation = { follows.append($0) }
        wire(store, api, sessions: ["sA"])
        await store.select("sA")
        let baseline = follows.count
        assert(baseline == 1, "the setup selection pointed the conversation at its session")
        let first = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "xhigh") }
        await spin { api.transport.calls("session/selectModel").count == 1 }
        api.transport.calls("session/selectModel")[0].respond(selected("provA", "m-defaulted", effort: "xhigh"))
        await spin { api.transport.calls("session/modelCatalog").count == 1 }
        api.transport.calls("session/modelCatalog")[0].respond(catalog("stale"))
        await spin { api.transport.calls("session/list").count == 1 }
        // The first selection's list refresh is parked; the newer one starts
        // on the same session and takes the seat.
        let second = Task { @MainActor in await store.selectModel(provider: "provA", model: "m-defaulted", effort: "low") }
        await spin { api.transport.calls("session/selectModel").count == 2 }
        api.transport.calls("session/list")[0].respond(list(["sA", "stale"]))
        await first.value
        assert(follows.count == baseline, "the stale .applied selection did not follow or reset the live conversation")
        assert(store.sessions.count == 1, "the stale selection's late list refreshed nothing")
        assert(store.model["reasoningEffort"].string == "xhigh", "the stale selection's accepted model stands")
        assert(store.error == nil, "no error before the newer selection answered")
        api.transport.calls("session/selectModel")[1].fail(HarnessError(message: "the Host rejected the effort"))
        await second.value
        assert(store.error == "Could not confirm the selected model: the Host rejected the effort", "the newer rejection is reported")
        assert(!store.selectingModel, "the busy state releases with the newer selection")
        print("PASS: production - a stale .applied selection keeps off the live conversation")
    }
}
