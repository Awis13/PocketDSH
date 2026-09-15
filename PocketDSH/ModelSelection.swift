import Foundation

// MARK: - Catalog reasoning

/// One catalog-advertised reasoning effort for a model. The id travels to the
/// Host as "reasoningEffort"; the name is what the UI shows.
struct ReasoningEffortOption: Equatable {
    let id: String
    let name: String
    let detail: String?

    init(_ value: JSON) {
        id = value["id"].string
        name = value["name"].string.isEmpty ? id : value["name"].string
        let d = value["description"].string
        detail = d.isEmpty ? nil : d
    }
}

/// The catalog "reasoning" block for one model: the efforts it supports and
/// the default the Host resolves when no explicit effort is sent.
struct ModelReasoning: Equatable {
    let efforts: [ReasoningEffortOption]
    /// nil when the model advertises no server-side default; the provider
    /// default then applies (the "reasoningEffort" field is omitted).
    let defaultEffort: String?

    init(efforts: [ReasoningEffortOption], defaultEffort: String?) {
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }
    /// The display name for an effort id; an unknown id is returned verbatim.
    func name(for id: String) -> String { efforts.first { $0.id == id }?.name ?? id }
}

/// Parse one catalog model's "reasoning" block. Returns nil when the model
/// advertises no reasoning (no selector, no fabricated default row).
func reasoning(for model: JSON) -> ModelReasoning? {
    let block = model["reasoning"]
    let efforts = block["efforts"].array.compactMap { e -> ReasoningEffortOption? in
        e["id"].string.isEmpty ? nil : ReasoningEffortOption(e)
    }
    guard !efforts.isEmpty else { return nil }
    let def = block["defaultEffort"].string
    return ModelReasoning(efforts: efforts, defaultEffort: def.isEmpty ? nil : def)
}

/// Find one catalog model row by provider and model id, or nil.
func catalogModel(provider: String, model: String, catalog: JSON) -> JSON? {
    for group in catalog["groups"].array where group["id"].string == provider {
        if let row = group["models"].array.first(where: { $0["id"].string == model }) { return row }
    }
    return nil
}

// MARK: - Effective effort

/// The effort a selection resolves to: the accepted "reasoningEffort" when the
/// Host returned one, else the model's advertised default; nil when the model
/// has no reasoning or the provider default applies. Unknown ids are preserved
/// verbatim, not dropped.
func effectiveEffortID(selection: JSON, model: JSON) -> String? {
    guard let reasoning = reasoning(for: model) else { return nil }
    let accepted = selection["reasoningEffort"].string
    return accepted.isEmpty ? reasoning.defaultEffort : accepted
}

/// The display label for a selection's effective effort, or nil when the model
/// has no reasoning to show. Unknown effort ids render verbatim.
func effectiveEffortLabel(selection: JSON, catalog: JSON) -> String? {
    guard let row = catalogModel(provider: selection["provider"].string, model: selection["model"].string, catalog: catalog),
          let reasoning = reasoning(for: row) else { return nil }
    guard let id = effectiveEffortID(selection: selection, model: row) else { return "Default" }
    return reasoning.name(for: id)
}

/// The selectable effort options for a model. A model with no advertised
/// default offers a "Default" row (the omitted field) ahead of its explicit
/// efforts; one with a default lists only its efforts (the default is one of
/// them, not a separate row).
struct EffortChoice: Identifiable, Equatable {
    /// The effort id to send; nil = provider default (the field is omitted).
    let effortID: String?
    let label: String
    var id: String { effortID ?? "<default>" }
}

func effortChoices(for model: JSON) -> [EffortChoice] {
    guard let reasoning = reasoning(for: model) else { return [] }
    var choices: [EffortChoice] = []
    if reasoning.defaultEffort == nil { choices.append(EffortChoice(effortID: nil, label: "Default")) }
    for effort in reasoning.efforts { choices.append(EffortChoice(effortID: effort.id, label: effort.name)) }
    return choices
}

/// Build the "session/selectModel" request. The optional effort is omitted
/// entirely when nil or empty (the provider default), never sent as an empty
/// string; a set effort travels verbatim.
func selectModelRequest(provider: String, model: String, effort: String?, sessionID: String) -> [String: JSON] {
    var request: [String: JSON] = ["sessionId": .string(sessionID), "provider": .string(provider), "model": .string(model)]
    let e = effort ?? ""
    if !e.isEmpty { request["reasoningEffort"] = .string(e) }
    return ["request": .object(request)]
}

// MARK: - The async selection seam

/// The production async model-selection path with operation ownership.
///
/// PocketStore keeps one instance and drives it from "selectModel"; the
/// offline checks drive the same object with a delayed fake transport, so the
/// request, the ownership and the response logic are the production code, not
/// a mirror. Every response is admitted only while the operation that sent it
/// is still the active one on a live session and connection; a superseded or
/// stale operation discards its result and never releases the busy state a
/// newer request now owns.
@MainActor
final class ModelSelectionGate {
    /// The identity one selection request was sent on: the session, endpoint,
    /// connection generation, the session-selection epoch, and the carrier
    /// attempt. A request is admitted only while all of these still match.
    final class Operation: Equatable {
        let sessionID: String
        let endpoint: String
        let generation: UUID
        let epoch: UUID
        let attempt: RemoteStreamConnection.RefreshToken?
        init(sessionID: String, endpoint: String, generation: UUID, epoch: UUID, attempt: RemoteStreamConnection.RefreshToken?) {
            self.sessionID = sessionID; self.endpoint = endpoint; self.generation = generation; self.epoch = epoch; self.attempt = attempt
        }
        static func == (a: Operation, b: Operation) -> Bool { a === b }
    }

    /// What one selection finished as.
    enum Outcome: Equatable {
        /// The selection was applied and the catalog refreshed.
        case applied
        /// The selection was applied; the catalog refresh failed (kept).
        case catalogFailed
        /// The selectModel request was rejected.
        case rejected
        /// The operation is no longer current; its response was discarded
        /// without touching the shared state.
        case stale
    }

    /// The operation that now owns the busy state, or nil when idle.
    private(set) var active: Operation?

    /// Run one selection. "live" reports whether "op" is still the active
    /// operation on a live session and connection; "rpc" is the transport. A
    /// response is applied only while "live" holds at that response boundary,
    /// so a deferred response cannot land after a newer request owns the seat.
    /// "onAccepted" receives the full accepted response - the caller extracts
    /// the selection from it; "onCatalog" receives the refreshed catalog.
    /// "onBusy(true)" marks the operation active, "onBusy(false)" releases the
    /// busy state - only the operation that was still active does.
    func select(provider: String, model: String, effort: String?,
                sessionID: String, endpoint: String, generation: UUID, epoch: UUID, attempt: RemoteStreamConnection.RefreshToken?,
                onBusy: @MainActor (Bool) -> Void,
                rpc: @MainActor (String, [String: JSON]) async throws -> JSON,
                live: @MainActor (Operation) -> Bool,
                onAccepted: @MainActor (JSON) -> Void,
                onCatalog: @MainActor (JSON) -> Void) async -> (outcome: Outcome, operation: Operation) {
        let op = Operation(sessionID: sessionID, endpoint: endpoint, generation: generation, epoch: epoch, attempt: attempt)
        active = op
        onBusy(true)
        var catalogOK = true
        do {
            let value = try await rpc("session/selectModel", selectModelRequest(provider: provider, model: model, effort: effort, sessionID: sessionID))
            guard live(op), active === op else { return settle(op, .stale, onBusy: onBusy) }
            onAccepted(value)
            do {
                let updated = try await rpc("session/modelCatalog", [:])
                guard live(op), active === op else { return settle(op, .stale, onBusy: onBusy) }
                onCatalog(updated)
            } catch {
                guard live(op), active === op else { return settle(op, .stale, onBusy: onBusy) }
                catalogOK = false
            }
            guard live(op), active === op else { return settle(op, .stale, onBusy: onBusy) }
            return settle(op, catalogOK ? .applied : .catalogFailed, onBusy: onBusy)
        } catch {
            guard live(op), active === op else { return settle(op, .stale, onBusy: onBusy) }
            return settle(op, .rejected, onBusy: onBusy)
        }
    }

    /// Release the busy flag only for the operation that still owns it. A
    /// superseded operation leaves the newer one's busy state untouched.
    private func settle(_ op: Operation, _ outcome: Outcome, onBusy: (Bool) -> Void) -> (outcome: Outcome, operation: Operation) {
        if active === op { active = nil; onBusy(false) }
        return (outcome, op)
    }
}
