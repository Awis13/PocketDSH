import Foundation

// DSH-REVIEW-3: one confirmation for every full-access escalation.
//
// The Host applies a permission preset the moment `commands/execute` reaches
// its handler (dsh-permission-presets/lib/index.js `apply`), so a switch the
// client sent without asking cannot be taken back by the client. Two surfaces
// reach that same line - the approval card's "Full access..." button and a
// composer command line - and both must pass the same confirmation first. This
// file holds that policy and the pending confirmation it guards as values
// `PocketStore` itself uses: no offline gate compiles the store, so a rule that
// lives only inside it can be found by reading alone.

/// Everything this client knows about the Host's access escalation: the line
/// that raises one session to full access, and the confirmation the user must
/// pass before that line is sent.
///
/// The Host's `/permission` command switches one entry of a preset table
/// (`name: "permission"`, `input: { hint: "<preset>" }`, handler comparing
/// `rawInput.trim()` against the preset names), and `danger-full-access` is the
/// entry that drops both the sandbox mode and the approval policy. The
/// reference client demands an explicit acknowledgement for exactly that preset
/// and no other (`dsh-client-ui-permission-presets/lib/client.js`: the option
/// whose `value === "danger-full-access"` carries the `confirmation` block) -
/// the rule kept here, including its copy.
enum FullAccessPolicy {
    /// The Host command that switches one session's permission preset.
    static let commandName = "permission"
    /// The preset that removes the sandbox and the approval prompts: the one
    /// entry that escalates rather than narrows or reports.
    static let presetName = "danger-full-access"
    /// The exact line both surfaces run to apply it.
    static let commandLine = "/" + commandName + " " + presetName

    /// The confirmation's copy, English like the rest of the composer. Both
    /// surfaces render these strings, so the two routes cannot promise
    /// different things about the same switch.
    static let title = "Enable full access for this session?"
    static let message = "The agent may change files and run external commands without further permission prompts in this session. Other sessions are unchanged."
    static let cancelLabel = "Cancel"
    /// The composer's confirmation has no card request to allow as well.
    static let commandEnableLabel = "Enable full access"
    /// The approval card's confirmation also decides the request it sits on.
    static let approvalEnableLabel = "Enable and allow this request"

    /// Whether one composer line asks the Host to raise this session to full
    /// access.
    ///
    /// Parsed by the Host's own parser and compared the way the Host's handler
    /// compares its argument (`rawInput.trim()` against the preset table), so
    /// only the exact switch escalates: a bare `/permission` reports the current
    /// preset, another preset narrows or reports instead, and an unknown name or
    /// a trailing argument is a line the Host rejects rather than applies. A
    /// line that does not parse as a command at all is never an escalation.
    static func isEscalation(line: String) -> Bool {
        guard let parsed = parseCommand(commandLineTrimmed(line)) else { return false }
        return parsed.name == commandName && commandLineTrimmed(parsed.rawInput) == presetName
    }
}

/// One pending access confirmation and the action it guards.
///
/// A class, like `CommandDirectory`, for two reasons: the store answers it from
/// an `async` context (a mutating method on a stored value type would fight the
/// property's exclusivity), and the offline checks then drive exactly the object
/// the store drives.
///
/// One at a time: the confirmation is a modal question about one action, so a
/// second request while the first is unanswered is refused instead of stacking a
/// second question (a double tap on a palette row asks once). The pending action
/// carries the composer snapshot it froze - line, attachments, session, endpoint
/// and catalog generation - and answering it re-checks that identity against the
/// live store, so a session switch or a reconnect between the question and the
/// answer sends nothing.
@MainActor
final class FullAccessGate {
    /// What a confirmed escalation runs.
    enum Target {
        /// A composer command line: the frozen action `executeCommand` resolved
        /// against the session's catalog, kept whole so the confirmation sends
        /// the line and the attachments the user sent - never the live composer.
        case command(ComposerSubmission, CommandDescriptor)
        /// An approval card: the escalation, and then the decision its button was
        /// going to give.
        case approval(Interaction)
    }

    /// One unanswered confirmation.
    struct Pending: Identifiable {
        let id: UUID
        let target: Target
        /// The enable button's label: what confirming this particular action does.
        let enableLabel: String
    }

    /// What answering a confirmation did.
    enum Outcome: Equatable {
        /// The action ran exactly once.
        case dispatched
        /// Nothing ran: the answer was late, repeated, or no longer applies to
        /// the live session and connection.
        case rejected
    }

    private(set) var pending: Pending?

    /// Open one confirmation, or nil when one is already unanswered.
    func request(_ target: Target) -> Pending? {
        guard pending == nil else { return nil }
        let row = Pending(id: UUID(), target: target, enableLabel: Self.enableLabel(for: target))
        pending = row
        return row
    }

    /// The user declined the question: the action is dropped unsent, and the
    /// composer it came from keeps its draft and attachments.
    @discardableResult
    func cancel(id: UUID) -> Bool {
        guard pending?.id == id else { return false }
        pending = nil
        return true
    }

    /// Drop an unanswered confirmation without a decision: the session or the
    /// connection it belongs to is gone, so its question is no longer answerable.
    func clear() { pending = nil }

    /// Answer the pending confirmation `id`.
    ///
    /// Exactly one action runs per confirmation. `id` must be the pending one: a
    /// second tap on an already-answered question, or a decision arriving after
    /// the pending action was dropped, finds nothing and runs nothing. The
    /// composer action additionally requires the store to be idle (`busy`) and
    /// the live session, endpoint and catalog generation to still be the ones its
    /// snapshot froze (`live`); when either moved, the action is dropped instead
    /// of being sent to whatever is open now.
    ///
    /// - Parameters:
    ///   - command: the composer action's transport - the store's
    ///     `commands/execute` leg.
    ///   - approval: the approval action's transport - the store's escalation
    ///     and answer legs.
    func confirm(id: UUID, live: LiveConnectionIdentity?, busy: Bool,
                 command: @MainActor (ComposerSubmission, CommandDescriptor) async -> Void,
                 approval: @MainActor (Interaction) async -> Void) async -> Outcome {
        guard let row = pending, row.id == id else { return .rejected }
        pending = nil
        switch row.target {
        case .command(let snapshot, let descriptor):
            guard !busy, let live, snapshot.stillApplies(live) else { return .rejected }
            await command(snapshot, descriptor)
        case .approval(let item):
            await approval(item)
        }
        return .dispatched
    }

    private static func enableLabel(for target: Target) -> String {
        switch target {
        case .command: return FullAccessPolicy.commandEnableLabel
        case .approval: return FullAccessPolicy.approvalEnableLabel
        }
    }
}

/// The production orchestration seam behind the full-access gate's lifecycle.
///
/// The store creates one and wires its carrier's failure and ready edges to it,
/// so a pending confirmation is dropped the moment the socket it was asked on
/// fails or a new attempt becomes ready. The invalidation lives here - in the
/// file the offline gate compiles - not in the store's private carrier glue,
/// which no offline check can reach: the store keeps only its published
/// `accessConfirmation` surface and the request/confirm/cancel legs it answers
/// from, while the question's lifetime across carrier events is the seam's.
@MainActor
final class ConfirmationLifecycle {
    /// The gate the seam owns; the store reads it for `request` and `confirm`.
    let gate: FullAccessGate
    init(_ gate: FullAccessGate) { self.gate = gate }

    /// The carrier's current attempt failed and is gone: its pending
    /// confirmation is stale and must not dispatch against a dead socket.
    func carrierFailed() { gate.clear() }
    /// A new attempt is ready - a fresh client id, a re-warmed catalog: an old
    /// attempt's confirmation no longer names the connection the user answers.
    func attemptReady() { gate.clear() }
    /// Selection or teardown dropped the composer the question was asked on.
    func reset() { gate.clear() }
}
