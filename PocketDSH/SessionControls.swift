import Foundation

// PARITY-2C C1: the session's control intents - the permission preset
// switch and the plan-mode toggle - frozen on the click and dispatched
// through the same commands/execute wire the composer's commands take.
//
// The wire contract, verified against the shipped Host packages
// (dsh-permission-presets, dsh-plan-mode, dsh-commands) and the reference
// client (dsh-client-ui-plan):
//
// - There is no remote permission setter. A permission change is the
//   `/permission <value>` line of commands/execute; the Host applies the
//   policy the moment the handler runs and republishes the `permissions`
//   projection. The client never writes that projection: the server's
//   frame is the only authority on the current value, so a control's
//   success ack moves nothing locally.
// - Plan mode is the `/plan` and `/plan off` lines. A bare `/plan` takes
//   no message and `/plan off` no attachments, so a control click never
//   mixes the composer's draft or images into the submission: the RPC
//   always carries exactly submittedAttachments: [] and never a
//   session/prompt.
// - The `plan` projection's `pending` flag means a transition is already
//   in flight toward the opposite state. A click during the flight asks
//   for nothing - the transition the user already requested is the
//   answer, and a second RPC would race the first for the same toggle.
// - The `danger-full-access` preset is the escalation. C1 recognizes it
//   and routes it to the future full-access gate (C2's
//   FullAccessGate.Target.control); it never sends the privileged line
//   directly.
//
// The freeze: the store builds the context synchronously on the main
// actor, at the click, from the live session, connection identity and
// projections. After the freeze the dispatch reads nothing else - every
// decision, and the liveness re-check after the RPC's suspension, reads
// the frozen context alone. A session switch, a reconnect or a
// capability change under the action stales it instead of landing its
// answer on the next identity.

/// One control click, frozen before any suspension.
enum SessionControlIntent: Equatable {
    /// Pick one row of the session's `permissions` projection.
    case permission(value: String)
    /// Toggle the session's plan mode.
    case plan
}

/// The frozen live view the store assembles on the click: the session and
/// the connection it rides, the generations the capability facts were read
/// from, the exact command catalog and the `permissions` and `plan`
/// projections at the moment of the click. After the freeze the dispatch
/// reads nothing else.
struct SessionControlContext: Equatable {
    let sessionID: String
    let endpoint: String
    /// The connection generation the click landed on.
    let generation: UUID
    /// The selection epoch the click landed on.
    let epoch: UUID
    /// The carrier attempt the click landed on; nil before the carrier
    /// mints one, always accepted like the other gates.
    let attempt: RemoteStreamConnection.RefreshToken?
    /// The command-catalog generation the advertised set was read from.
    let catalogGeneration: Int
    /// The agentPresets/list pull generation the accepted capability state
    /// was read from.
    let presetGeneration: Int
    /// The session's advertised commands at the click.
    let catalog: [CommandDescriptor]
    /// The session's `permissions` projection at the click; nil when the
    /// capability is not advertised.
    let permissions: PermissionSelect?
    /// The session's `plan` projection at the click; nil when the
    /// capability is not advertised.
    let plan: PlanProjection?
}

/// Why a frozen permission click asks for no change.
enum SessionControlNoChange: Equatable {
    /// `custom` is a display row the projection appends, not a switch
    /// target the Host accepts.
    case customPermission
    /// The row is no longer offered by the frozen projection.
    case removedPermission
    /// The row is already the current value: the switch is a no-op.
    case currentPermission
    /// A plan transition is already in flight; it owns the toggle.
    case planPending
}

/// Why a frozen click finds no capability to act on.
enum SessionControlCapability: Equatable {
    case permissionProjection
    case permissionCommand
    case planProjection
    case planCommand
}

/// What a frozen intent resolves to, decided before any suspension.
enum SessionControlDecision: Equatable {
    /// Send exactly this line with submittedAttachments: [].
    case line(String)
    /// The value is the full-access escalation: recognized and routed to
    /// the future gate; no direct commands/execute in C1.
    case routedToFullAccess
    case noChange(SessionControlNoChange)
    case capabilityMissing(SessionControlCapability)
}

/// The outcome of one frozen control action.
enum SessionControlOutcome: Equatable {
    /// The exact line was sent on the frozen connection. The server's
    /// `permissions` / `plan` projection - not this outcome - is what
    /// moves the state.
    case sent(line: String)
    case routedToFullAccess
    case noChange(SessionControlNoChange)
    case capabilityMissing(SessionControlCapability)
    /// The identity moved under the action: the answer was discarded and
    /// wrote nothing.
    case stale
    /// The RPC refused or failed; the message is the store's visible error.
    case failed(String)
}

/// The decisions of one frozen intent, and the wire lines they resolve to.
enum SessionControls {
    /// The exact commands/execute line of a frozen permission value.
    static func permissionLine(_ value: String) -> String {
        "/" + FullAccessPolicy.commandName + " " + value
    }

    /// The plan line of a frozen state: the toggle away from the state the
    /// session is actually in. A pending transition owns the toggle, so a
    /// pending click sends nothing.
    static func planLine(active: Bool, pending: Bool) -> String? {
        guard !pending else { return nil }
        return active ? "/plan off" : "/plan"
    }

    /// Decide one frozen intent against the frozen context.
    static func decide(_ intent: SessionControlIntent, _ context: SessionControlContext) -> SessionControlDecision {
        switch intent {
        case .permission(let value): return decidePermission(value, context: context)
        case .plan: return decidePlan(context: context)
        }
    }

    static func decidePermission(_ value: String, context: SessionControlContext) -> SessionControlDecision {
        guard context.permissions != nil else { return .capabilityMissing(.permissionProjection) }
        guard context.catalog.contains(where: { $0.name == FullAccessPolicy.commandName }) else {
            return .capabilityMissing(.permissionCommand)
        }
        if value == "custom" { return .noChange(.customPermission) }
        guard let options = context.permissions?.options, options.contains(where: { $0.value == value }) else {
            return .noChange(.removedPermission)
        }
        if context.permissions?.currentValue == value { return .noChange(.currentPermission) }
        if value == FullAccessPolicy.presetName { return .routedToFullAccess }
        return .line(permissionLine(value))
    }

    static func decidePlan(context: SessionControlContext) -> SessionControlDecision {
        guard let plan = context.plan else { return .capabilityMissing(.planProjection) }
        guard context.catalog.contains(where: { $0.name == "plan" }) else {
            return .capabilityMissing(.planCommand)
        }
        guard let line = planLine(active: plan.active, pending: plan.pending) else {
            return .noChange(.planPending)
        }
        return .line(line)
    }

    /// The visible errors of one refused answer, the reference client's own
    /// wording for the shape it met.
    static func unknownCommandMessage(line: String) -> String { "Unknown or malformed command: " + line }
    static func malformedResultMessage(line: String) -> String { "Malformed command result: " + line }
    static func commandFailedMessage(line: String) -> String { line + " failed" }
}

/// One frozen control action: the intent, the frozen live view, and the
/// decision taken on the freeze. A class, like the other gates'
/// operations: the store keeps the reference and judges ownership by
/// identity after each suspension.
@MainActor
final class SessionControlOperation: Equatable {
    let id: UUID
    let intent: SessionControlIntent
    let context: SessionControlContext
    let decision: SessionControlDecision
    init(intent: SessionControlIntent, context: SessionControlContext) {
        self.id = UUID()
        self.intent = intent
        self.context = context
        self.decision = SessionControls.decide(intent, context)
    }
    static func == (a: SessionControlOperation, b: SessionControlOperation) -> Bool { a === b }
}

/// The production coordinator of the session's control actions: one frozen
/// action at a time, the seat a click takes before any suspension, and the
/// invalidation that drops it when the session or the connection it belongs
/// to moves on. A late answer of a dropped action settles stale and touches
/// nothing - the same ownership the preset switch owns its switch with.
@MainActor
final class SessionControlGate {
    /// The action that now owns the seat, or nil when idle.
    private(set) var active: SessionControlOperation?

    /// Freeze one click and take the seat. A second click before the first
    /// settled is refused - the caller keeps its own answer, never a
    /// supersede.
    func begin(_ intent: SessionControlIntent, _ context: SessionControlContext) -> SessionControlOperation? {
        guard active == nil else { return nil }
        let op = SessionControlOperation(intent: intent, context: context)
        active = op
        return op
    }

    /// Run one frozen action. The decisions that ask for nothing settle
    /// without a suspension; the line decision suspends on `rpc` and
    /// re-checks `live` at the answer boundary - a moved identity discards
    /// the answer (.stale) and writes nothing. The success ack writes no
    /// projection: the server's `permissions` / `plan` frame is the only
    /// writer of those states.
    func dispatch(_ op: SessionControlOperation,
                  live: @MainActor (SessionControlOperation) -> Bool,
                  rpc: @MainActor (String) async throws -> JSON) async -> SessionControlOutcome {
        defer { settle(op) }
        switch op.decision {
        case .noChange(let reason):
            return .noChange(reason)
        case .capabilityMissing(let capability):
            return .capabilityMissing(capability)
        case .routedToFullAccess:
            return .routedToFullAccess
        case .line(let line):
            do {
                let value = try await rpc(line)
                guard live(op) else { return .stale }
                let execution = CommandExecution(value)
                if execution.result.isSuccess {
                    return .sent(line: line)
                }
                if value == .null {
                    return .failed(SessionControls.unknownCommandMessage(line: line))
                }
                if execution.result.isError {
                    return .failed(execution.result.text ?? SessionControls.commandFailedMessage(line: line))
                }
                return .failed(SessionControls.malformedResultMessage(line: line))
            } catch {
                guard live(op) else { return .stale }
                return .failed(error.localizedDescription)
            }
        }
    }

    /// Drop the seat of an action whose session or connection moved on: a
    /// selection change or a disconnect. Its late answer settles stale and
    /// touches nothing.
    func invalidate() {
        active = nil
    }

    /// Release the seat of the action that still holds it.
    private func settle(_ op: SessionControlOperation) {
        if active === op { active = nil }
    }
}
