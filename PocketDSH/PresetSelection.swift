import Foundation

// PARITY-2B B2: the preset roster, the session/create request builder, and
// the operation-owned Create outcome. The roster comes from
// agentPresets/list - the Host re-reads it on every list, so the app keeps no
// cache of its own and re-pulls it when the picker opens and when a new
// connection lands. The default is encoded by the ABSENCE of agentPreset in
// the create request; an explicit choice sends the exact advertised id. The
// Create outcome is owned by the operation that was issued, never inferred
// from whatever session happens to be selected afterwards.

/// One roster row as agentPresets/list serves it.
struct AgentPresetRow: Identifiable, Equatable {
    let id: String
    let trust: String
    let isDefault: Bool
    let name: String
    let detail: String
    /// Why the preset cannot compose a session; absent when it can.
    let broken: String?
    /// A row is selectable unless the Host says why it cannot compose.
    var selectable: Bool { broken == nil }
    /// The picker's label: the published name, falling back to the id.
    var title: String { name.isEmpty ? id : name }

    init(id: String, trust: String, isDefault: Bool, name: String = "", detail: String = "", broken: String? = nil) {
        self.id = id; self.trust = trust; self.isDefault = isDefault
        self.name = name; self.detail = detail; self.broken = broken
    }

    /// Parse one wire row. A row without a non-empty id is not a row.
    init?(_ wire: JSON) {
        let id = wire["id"].string
        guard !id.isEmpty else { return nil }
        self.id = id
        self.trust = wire["trust"].string
        self.isDefault = wire["isDefault"].bool
        self.name = wire["name"].string
        self.detail = wire["description"].string
        let broken = wire["broken"].string
        self.broken = broken.isEmpty ? nil : broken
    }
}

/// The roster state the picker renders.
enum AgentPresetRosterState: Equatable {
    /// The picker is open and agentPresets/list has not answered yet.
    case loading
    /// The roster as served, in the order the Host serves it.
    case loaded(rows: [AgentPresetRow], authorable: Bool)
    /// The list answered without a presets array: no advertised presets.
    case missing
    /// The list failed on this connection.
    case failed(String)
}

/// One option the preset picker offers.
struct PresetPickerOption: Identifiable, Equatable {
    /// nil is the host default, encoded as an omitted agentPreset.
    let presetID: String?
    let title: String
    let selectable: Bool
    /// Why the row is unselectable (a broken or removed preset), if any.
    let reason: String?
    let isDefault: Bool
    var id: String { presetID ?? "default" }

    init(presetID: String?, title: String, selectable: Bool, reason: String? = nil, isDefault: Bool = false) {
        self.presetID = presetID; self.title = title; self.selectable = selectable
        self.reason = reason; self.isDefault = isDefault
    }

    /// The host default: always the first option, always selectable, never
    /// mutated by the roster.
    static let `default` = PresetPickerOption(presetID: nil, title: "Server default", selectable: true, reason: nil, isDefault: true)
}

enum PresetSelection {
    /// The exact wire request of session/create. The workspace and the preset
    /// follow the same omission rule: absent or empty means the key is absent
    /// from the request, never an empty string on the wire.
    static func createRequest(sessionID: String, workspaceID: String?, agentPreset: String?) -> [String: JSON] {
        var request: [String: JSON] = ["sessionId": .string(sessionID)]
        if let workspaceID, !workspaceID.isEmpty { request["workspaceId"] = .string(workspaceID) }
        if let agentPreset, !agentPreset.isEmpty { request["agentPreset"] = .string(agentPreset) }
        return request
    }

    /// The picker's options: the host default first, then the advertised rows
    /// in the order the Host serves them. A staged id the loaded roster no
    /// longer advertises is a removed selection: it stays shown, verbatim,
    /// with its removal reason and unselectable - exactly like a removed row.
    /// While the roster is not loaded the removal cannot be told, so a staged
    /// id stays selectable, shown verbatim.
    static func pickerOptions(roster: AgentPresetRosterState, staged: String?) -> [PresetPickerOption] {
        var options: [PresetPickerOption] = [.default]
        var rosterLoaded = false
        if case .loaded(let rows, _) = roster {
            rosterLoaded = true
            options += rows.map { PresetPickerOption(presetID: $0.id, title: $0.title, selectable: $0.selectable, reason: $0.broken, isDefault: $0.isDefault) }
        }
        if let staged, !options.contains(where: { $0.presetID == staged }) {
            options.append(PresetPickerOption(presetID: staged, title: staged, selectable: !rosterLoaded,
                                              reason: rosterLoaded ? "No longer offered by the server" : nil, isDefault: false))
        }
        return options
    }
}

/// One Create operation and the context it was issued under. Everything the
/// outcome depends on - the requested identity, the workspace and preset the
/// caller chose, the connection generation, the selection epoch and the
/// carrier attempt - is captured before the first await, so the answer can
/// only be the outcome of THIS create.
struct CreateOperation: Equatable {
    let id: UUID
    let requestedSessionID: String
    let workspaceID: String?
    let agentPreset: String?
    let endpoint: String
    let generation: UUID
    let epoch: UUID
    let attempt: RemoteStreamConnection.RefreshToken?
}

/// The outcome of one Create operation.
enum CreateOutcome: Equatable {
    /// The create completed and this operation's side effects landed.
    case created(sessionID: String, agentPreset: String?)
    /// The Host created the session, but it could not attach to the requested
    /// workspace. The session may already exist: the list may be refreshed on
    /// the same live connection, but this is not a success, nothing is
    /// selected, and the caller must not retry automatically.
    case attachFailed(sessionID: String, workspaceID: String)
    /// The create failed; nothing was adopted.
    case failed(String)
    /// The operation was superseded, or its connection or session moved on
    /// before the answer landed: nothing was applied.
    case stale
}

/// The result of the native open that a select attempted, if any. The native
/// create judges its outcome against this: only a confirmed open is a
/// success - a rejected open is a visible failure, not a stale.
enum NativeOpenOutcome {
    /// No native open was attempted: a DSH backend, or a deselect.
    case none
    /// The native open frame was confirmed by the connection.
    case opened
    /// The native open frame was rejected; select published the error.
    case failed
}

/// The result of one call to PocketStore.create.
struct CreateResult: Equatable {
    let operation: CreateOperation
    let outcome: CreateOutcome
    /// NewTaskView's dismiss rule: only a confirmed success of the very
    /// operation this sheet instance issued closes the sheet. A failure, an
    /// attach-failed and a stale answer all leave it open - and none of them
    /// can close a newer sheet, because only this instance reads this result.
    var dismissesSheet: Bool {
        if case .created = outcome { return true }
        return false
    }
}

/// The production owner of the in-flight session Create. The store's create
/// takes the seat before its first await and settles the outcome into it; a
/// session switch or a disconnect drops the seat, so a late answer can apply
/// nothing.
@MainActor
final class CreateSheetOwnership {
    private(set) var active: CreateOperation?
    /// The latest settled outcome, with the operation it belongs to.
    private(set) var settled: (operation: CreateOperation, outcome: CreateOutcome)?

    func begin(_ operation: CreateOperation) {
        active = operation
        settled = nil
    }
    func stillOwns(_ operation: CreateOperation) -> Bool { active?.id == operation.id }
    func settle(_ operation: CreateOperation, _ outcome: CreateOutcome) {
        let wasActive = active?.id == operation.id
        if wasActive { active = nil }
        // Only the operation that still held the seat - or the first settle
        // after a begin - publishes its outcome: a stale older operation
        // settling late, after a newer operation already settled, must not
        // clobber the newer outcome.
        if wasActive || settled == nil || settled?.operation.id == operation.id {
            settled = (operation: operation, outcome: outcome)
        }
    }
    /// A session switch or a disconnect: the in-flight create loses its seat.
    func invalidate() { active = nil }
}

// MARK: - B3: the blank-session preset switch

/// The display name for an accepted preset id: the loaded roster's published
/// name when it lists the id, the id itself otherwise. An accepted id the
/// roster no longer advertises is shown verbatim, never hidden - the
/// projection is the server's fact about what the session runs on.
func presetDisplayName(_ id: String, roster: AgentPresetRosterState) -> String {
    if case .loaded(let rows, _) = roster {
        for row in rows where row.id == id { return row.title }
    }
    return id
}

/// The production async preset-switch path with operation ownership, the same
/// seam ModelSelectionGate is for model selection: PocketStore keeps one
/// instance and drives it from `selectPreset`; the offline checks drive the
/// same object with a delayed fake transport, so the request, the ownership
/// and the response logic are the production code, not a mirror.
///
/// A switch is only issued for a blank session - `sessionListMetadata.blank`
/// is the Host's own fact about the blank window, never `!running`, never
/// transcript emptiness. The request is `agentPresets/select` with the
/// session and the chosen preset id; the Host's strict result is the accepted
/// preset id. The accepted state itself is server-owned: it arrives as the
/// `agentPreset` projection on the session list, and the client never writes
/// it. The command catalog is invalidated by the Host's own
/// `agent-preset/selected` event (the existing `CommandCatalog` path) - the
/// switch itself issues no catalog pull, so nothing refreshes twice.
@MainActor
final class PresetSwitchGate {
    /// The identity one switch request was sent on: the session, endpoint,
    /// connection generation, the session-selection epoch and the carrier
    /// attempt. The request is admitted only while all of these still hold.
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

    /// What one switch finished as.
    enum Outcome: Equatable {
        /// agentPresets/select returned the accepted preset id.
        case accepted
        /// The Host refused the switch; the store published the error.
        case rejected
        /// The operation is no longer current; its answer was discarded
        /// without touching the shared state.
        case stale
    }

    /// The operation that now owns the busy state, or nil when idle.
    private(set) var active: Operation?
    /// The busy closure of the active operation, retained so invalidateCurrent
    /// can release the busy state of an operation it drops.
    private var busy: (@MainActor (Bool) -> Void)?

    /// Run one switch. "op" is the operation the caller created - and thereby
    /// owns - and keeps for its own ownership checks after the response;
    /// "live" reports whether "op" is still current on a live session and
    /// connection at each response boundary; "onAccepted" receives the
    /// accepted preset id the Host returned and runs the post-accept effects -
    /// list refresh, model/effort catalog, re-follow - re-checking ownership
    /// across its own awaits; "onRejected" receives the rejection. A response
    /// is applied only while "live" holds at that boundary, so a deferred
    /// answer cannot land after a session switch, a supersede or a reconnect.
    /// "onBusy(true)" marks the operation active, "onBusy(false)" releases the
    /// busy state - only the operation that was still active does.
    func select(_ op: Operation, presetID: String,
                onBusy: @escaping @MainActor (Bool) -> Void,
                rpc: @MainActor (String) async throws -> JSON,
                live: @MainActor (Operation) -> Bool,
                onAccepted: @escaping @MainActor (String) async -> Void,
                onRejected: @MainActor (Error) -> Void) async -> (outcome: Outcome, operation: Operation) {
        active = op
        busy = onBusy
        onBusy(true)
        do {
            let value = try await rpc(presetID)
            guard live(op), active === op else { return settle(op, .stale) }
            await onAccepted(value.string)
            guard live(op), active === op else { return settle(op, .stale) }
            return settle(op, .accepted)
        } catch {
            guard live(op), active === op else { return settle(op, .stale) }
            onRejected(error)
            return settle(op, .rejected)
        }
    }

    /// Release the busy flag only for the operation that still owns it. A
    /// superseded operation leaves the newer one's busy state untouched.
    private func settle(_ op: Operation, _ outcome: Outcome) -> (outcome: Outcome, operation: Operation) {
        if active === op { active = nil; busy?(false) }
        return (outcome, op)
    }

    /// The session or the connection itself has moved on: the in-flight
    /// switch can no longer land, so its ownership - and the busy state it
    /// owns - are dropped immediately. A late response of the dropped
    /// operation settles stale and touches nothing, because the seat no
    /// longer holds it.
    func invalidateCurrent() {
        guard active != nil else { return }
        active = nil
        busy?(false)
    }
}
