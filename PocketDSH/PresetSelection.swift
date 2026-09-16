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
