import Foundation

// DSH-REVIEW-3: one confirmation for every full-access escalation.
//
// Every assertion below drives the production values the store itself uses -
// `FullAccessPolicy`, `FullAccessGate`, `resolveCommandDispatch`,
// `commandExecuteArguments`, `ComposerDrafts` - never a copy of them. The
// dispatch behind the question sits on a controlled transport: a recorder that
// builds the very `commands/execute` arguments the store's leg builds, so "no
// call before the confirmation, exactly one after it" is counted on the wire
// shape instead of on the store's private glue, which no offline gate compiles.

/// The controlled transport: the store's `commands/execute` leg, recorded.
@MainActor
final class RecordingTransport {
    /// Every dispatched `commands/execute`, exactly as the store would send it.
    private(set) var calls: [[String: JSON]] = []

    func execute(_ snapshot: ComposerSubmission, _ descriptor: CommandDescriptor) async {
        let submitted = submissionAttachments(snapshot.images) ?? []
        calls.append(commandExecuteArguments(agentId: snapshot.sessionID, line: snapshot.text, submittedAttachments: submitted))
    }

    var lines: [String] { calls.map { $0["line"]?.string ?? "" } }
    var agents: [String] { calls.map { $0["agentId"]?.string ?? "" } }
    var attachmentCounts: [Int] { calls.map { $0["submittedAttachments"]?.array.count ?? -1 } }
    var attachmentNames: [[String]] { calls.map { ($0["submittedAttachments"]?.array ?? []).map { $0["name"].string } } }
}

@main struct FullAccessConfirmationChecks {
    static let host = "https://dsn.example"
    static func json(_ s: String) -> JSON { try! JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }

    /// A catalog row: `input` nil means the command declares no input line,
    /// otherwise the row declares one, with the given hint.
    static func descriptor(_ name: String, input: Bool = false, hint: String = "<preset>", attachments: Bool? = nil) -> CommandDescriptor {
        guard input else { return CommandDescriptor(json(#"{"name":"\#(name)","description":"d"}"#)) }
        let flag = attachments.map { ",\"attachments\":\($0)" } ?? ""
        return CommandDescriptor(json(#"{"name":"\#(name)","description":"d","input":{"hint":"\#(hint)"\#(flag)}}"#))
    }
    /// The Host's own `/permission` row: an input line hinting its preset
    /// argument, and no attachment input (dsh-permission-presets/lib/index.js).
    static var permissionRow: CommandDescriptor { descriptor("permission", input: true) }
    /// The catalog a DSH session serves: the escalation plus ordinary commands.
    static var catalog: [CommandDescriptor] {
        [permissionRow, descriptor("compact", input: true, hint: "compact [reason]", attachments: true), descriptor("goal"), descriptor("help")]
    }
    static func image(_ name: String) -> OutgoingImage {
        OutgoingImage(id: UUID(), data: Data(name.utf8), mediaType: "image/jpeg", name: name)
    }
    static func composer(draft: String, images: [OutgoingImage] = [], session: String = "s1",
                         endpoint: String = host, generation: Int = 1, version: Int = 0) -> ComposerSubmission {
        ComposerSubmission(draft: draft, images: images, sessionID: session, endpoint: endpoint,
                           catalogGeneration: generation, draftVersion: version)
    }
    static func live(session: String? = "s1", endpoint: String = host, generation: Int = 1) -> LiveConnectionIdentity {
        LiveConnectionIdentity(sessionID: session, endpoint: endpoint, catalogGeneration: generation)
    }
    /// One approval card as the store receives it.
    static func approval(_ id: String = "e1", session: String = "s1") -> Interaction {
        Interaction(raw: json(#"{"event":"approval/request","eventId":"\#(id)","agentId":"\#(session)","request":{"toolName":"bash"}}"#), clientID: "c1")
    }
    /// Answer one question the way the store answers it: the composer leg is the
    /// controlled transport, the approval leg is counted.
    @MainActor
    static func answer(_ gate: FullAccessGate, _ id: UUID, live: LiveConnectionIdentity?, busy: Bool = false,
                       sent: RecordingTransport, approvals: @escaping () -> Void = {}) async -> FullAccessGate.Outcome {
        await gate.confirm(id: id, live: live, busy: busy,
                           command: { snapshot, descriptor in await sent.execute(snapshot, descriptor) },
                           approval: { _ in approvals() })
    }

    @MainActor
    static func main() async {
        // 1. The policy: exactly one line escalates.
        //
        // The line is parsed by the Host's parser and its argument compared the
        // way the Host's handler compares it (`rawInput.trim()` against the
        // preset table), so a bare `/permission` (which only reports the current
        // preset), another preset, an unknown name and a rejected trailing
        // argument all stay ordinary commands.
        assert(FullAccessPolicy.commandLine == "/permission danger-full-access")
        assert(FullAccessPolicy.isEscalation(line: "/permission danger-full-access"))
        assert(FullAccessPolicy.isEscalation(line: "  /permission danger-full-access  "), "the reference trims the line before it parses")
        assert(FullAccessPolicy.isEscalation(line: "/permission  danger-full-access"), "rawInput is trimmed before the preset comparison")
        assert(FullAccessPolicy.isEscalation(line: "/permission\tdanger-full-access"), "a tab separates the argument like the Host's parser")
        assert(FullAccessPolicy.isEscalation(line: "/permission danger-full-access\u{00A0}"), "the JS trim class includes NBSP")
        assert(!FullAccessPolicy.isEscalation(line: "/permission"), "a bare /permission only reports the current preset")
        assert(!FullAccessPolicy.isEscalation(line: "/permission workspace-write"), "a narrowing preset is not an escalation")
        assert(!FullAccessPolicy.isEscalation(line: "/permission danger-full-access now"), "a trailing argument is a preset the Host rejects, not applies")
        assert(!FullAccessPolicy.isEscalation(line: "/permissions danger-full-access"), "another command name is not the switch")
        assert(!FullAccessPolicy.isEscalation(line: "permission danger-full-access"), "a line that does not parse as a command never escalates")
        assert(!FullAccessPolicy.isEscalation(line: ""))
        print("PASS: only the exact /permission danger-full-access line escalates")

        // 2. The catalog still decides what is a command at all: the escalation
        // is reached only through a row the session's catalog serves, and every
        // ordinary claimed line runs without a question.
        guard case .execute(let claimed) = resolveCommandDispatch(composer(draft: "/permission danger-full-access"), descriptors: catalog) else {
            return assert(false, "the catalog row claims its own line")
        }
        assert(claimed.name == "permission" && FullAccessPolicy.isEscalation(line: "/permission danger-full-access"))
        for line in ["/compact", "/goal", "/help", "/permission", "/permission workspace-write"] {
            guard case .execute(let row) = resolveCommandDispatch(composer(draft: line), descriptors: catalog) else {
                return assert(false, "\(line) is claimed by the catalog")
            }
            assert(row.name == submittedCommandName(line), "the row is the catalog's own description of the line")
            assert(!FullAccessPolicy.isEscalation(line: line), "\(line) is an ordinary command and asks nothing")
        }
        // A line no catalog row claims never reaches the escalation: it falls
        // through to the message path, exactly like any other unknown command.
        assert(resolveCommandDispatch(composer(draft: "/permission danger-full-access"), descriptors: [descriptor("help")]) == .message,
               "an unclaimed escalation line is a message, not a switch")
        print("PASS: the catalog stays the source of command descriptions")

        // 3. Cancel: the question is dropped, nothing is sent, and the composer
        // keeps the draft and the attachments the user sent.
        let transported = RecordingTransport()
        let gate = FullAccessGate()
        let sent = composer(draft: "/permission danger-full-access", images: [image("a.jpg")])
        guard let pending = gate.request(.command(sent, permissionRow)) else { return assert(false, "the first request opens the question") }
        assert(pending.enableLabel == "Enable full access", "the composer's label names what confirming does")
        assert(gate.pending?.id == pending.id)
        assert(transported.calls.isEmpty, "a question sends nothing")
        assert(gate.cancel(id: UUID()) == false, "an answer to another question cancels nothing")
        assert(gate.pending?.id == pending.id, "the question survives a foreign cancel")
        assert(gate.cancel(id: pending.id) && gate.pending == nil)
        let cancelled = await answer(gate, pending.id, live: live(), sent: transported)
        let cancelledAgain = await answer(gate, pending.id, live: live(), sent: transported)
        assert(cancelled == .rejected && cancelledAgain == .rejected, "a cancelled question cannot be confirmed afterwards")
        assert(transported.calls.isEmpty, "cancel and its late confirmations send nothing")
        assert(sent.draft == "/permission danger-full-access" && sent.imageIDs.count == 1, "the snapshot keeps the draft and its attachments")
        print("PASS: cancel sends nothing and keeps the draft and attachments")

        // 4. Confirm: exactly one `commands/execute`, addressed to the frozen
        // session, carrying the frozen line and the frozen attachments - even
        // when the live composer holds something else by then.
        let confirmed = RecordingTransport()
        let gateB = FullAccessGate()
        let frozen = composer(draft: "/permission danger-full-access", images: [image("a.jpg")], session: "s1", generation: 7)
        guard let asked = gateB.request(.command(frozen, permissionRow)) else { return assert(false, "the request opens the question") }
        let liveDraftAfterTyping = "a completely new draft"
        let outcome = await answer(gateB, asked.id, live: live(generation: 7), sent: confirmed)
        assert(outcome == .dispatched)
        assert(confirmed.calls.count == 1, "one confirmation is one call")
        assert(confirmed.lines == ["/permission danger-full-access"], "the call carries the line the user sent")
        assert(confirmed.agents == ["s1"], "the call is addressed to the session the action was frozen in")
        assert(confirmed.attachmentCounts == [1] && confirmed.attachmentNames == [["a.jpg"]], "the frozen attachment rides with the line")
        assert(gateB.pending == nil, "the question is consumed by its answer")
        // The draft typed while the question was on screen is a new draft: the
        // send's cleanup rule keeps it, and drops only what actually went out.
        assert(!frozen.isSentDraft(liveDraftAfterTyping, version: 1) && frozen.draftAfterSend(liveDraftAfterTyping, version: 1) == liveDraftAfterTyping,
               "the draft typed while the question was up is not the one that was sent")
        print("PASS: confirming dispatches exactly one commands/execute with the frozen action")

        // 5. Double confirm: the second answer to the same question runs
        // nothing, and no question is re-opened by it.
        let doubled = await answer(gateB, asked.id, live: live(generation: 7), sent: confirmed)
        let doubledAgain = await answer(gateB, asked.id, live: live(generation: 7), sent: confirmed)
        assert(doubled == .rejected && doubledAgain == .rejected)
        assert(confirmed.calls.count == 1, "a doubled confirmation never doubles the call")
        assert(gateB.pending == nil, "a doubled answer re-opens nothing")
        print("PASS: a double confirmation is rejected")

        // 6. One question at a time: a second request while the first is
        // unanswered is refused, because two questions over one composer are two
        // answers to one action.
        let gateC = FullAccessGate()
        let first = composer(draft: "/permission danger-full-access")
        guard let question = gateC.request(.command(first, permissionRow)) else { return assert(false, "the first request opens the question") }
        assert(gateC.request(.command(first, permissionRow)) == nil, "a second request while one is pending is refused")
        assert(gateC.request(.approval(approval())) == nil, "the refusal holds across both routes")
        assert(gateC.pending?.id == question.id, "the unanswered question is still the pending one")
        assert(gateC.cancel(id: question.id))
        assert(gateC.request(.approval(approval())) != nil, "the route is free again once the question is answered")
        print("PASS: at most one escalation question is pending")

        // 7. Stale answers send nothing: a session switch, a reconnect (same
        // Host, same session, new catalog generation) and a disconnect all leave
        // the frozen action unanswerable.
        let staleTransport = RecordingTransport()
        for moved in [live(session: "s2"), live(session: nil), live(endpoint: "https://other.example"),
                      live(generation: 8), live(session: "s2", generation: 8)] {
            let gateD = FullAccessGate()
            let action = composer(draft: "/permission danger-full-access", session: "s1", generation: 7)
            guard let row = gateD.request(.command(action, permissionRow)) else { return assert(false, "the request opens the question") }
            let movedOutcome = await answer(gateD, row.id, live: moved, sent: staleTransport)
            assert(movedOutcome == .rejected, "an answer from a moved session or connection is rejected")
            assert(gateD.pending == nil, "the stale question is dropped, not re-armed")
        }
        assert(staleTransport.calls.isEmpty, "a stale answer sends nothing")
        // A disconnected store has no live identity at all.
        let gateE = FullAccessGate()
        guard let rowE = gateE.request(.command(composer(draft: "/permission danger-full-access"), permissionRow)) else { return assert(false, "the request opens the question") }
        let disconnected = await answer(gateE, rowE.id, live: nil, sent: staleTransport)
        assert(disconnected == .rejected && staleTransport.calls.isEmpty)
        // The store drops the question on the way out (a session switch, a
        // reconnect, a teardown), so a late tap on a dismissed alert cannot
        // answer it.
        let gateF = FullAccessGate()
        guard let rowF = gateF.request(.command(composer(draft: "/permission danger-full-access"), permissionRow)) else { return assert(false, "the request opens the question") }
        gateF.clear()
        let withdrawn = await answer(gateF, rowF.id, live: live(), sent: staleTransport)
        assert(withdrawn == .rejected && staleTransport.calls.isEmpty, "a withdrawn question cannot be answered")
        print("PASS: a session switch, a reconnect and a teardown all drop the pending action")

        // 8. A store already sending something else does not start a second
        // action behind the question: the confirmation is rejected, not queued.
        let busyTransport = RecordingTransport()
        let gateG = FullAccessGate()
        guard let rowG = gateG.request(.command(composer(draft: "/permission danger-full-access"), permissionRow)) else { return assert(false, "the request opens the question") }
        let busyOutcome = await answer(gateG, rowG.id, live: live(), busy: true, sent: busyTransport)
        assert(busyOutcome == .rejected && busyTransport.calls.isEmpty, "a busy store sends nothing for a confirmation it refused")
        assert(gateG.pending == nil, "the refused confirmation is consumed, not left armed")
        print("PASS: a confirmation cannot start while another send owns the store")

        // 9. The approval route asks the same question and runs only its own
        // leg: a cancel runs neither, and a confirm runs the card's transport -
        // the escalation followed by the decision - never the composer's.
        let gateH = FullAccessGate()
        guard let rowH = gateH.request(.approval(approval())) else { return assert(false, "the approval request opens the question") }
        assert(rowH.enableLabel == "Enable and allow this request", "the card's label names both effects")
        assert(gateH.cancel(id: rowH.id))
        var approvalRuns = 0
        var composerRuns = 0
        let cancelledCard = await gateH.confirm(id: rowH.id, live: live(), busy: false,
                                                command: { _, _ in composerRuns += 1 }, approval: { _ in approvalRuns += 1 })
        assert(cancelledCard == .rejected && approvalRuns == 0 && composerRuns == 0, "a cancelled card question runs nothing")
        guard let rowI = gateH.request(.approval(approval("e2"))) else { return assert(false, "the approval request opens the question") }
        let cardOutcome = await gateH.confirm(id: rowI.id, live: live(), busy: true,
                                              command: { _, _ in composerRuns += 1 }, approval: { _ in approvalRuns += 1 })
        assert(cardOutcome == .dispatched && approvalRuns == 1 && composerRuns == 0,
               "the card's confirmation is not the composer's send and runs exactly the card's leg")
        print("PASS: the approval card asks the same question and runs only its own leg")

        // 10. A fault on the wire and the draft: the escalation is dispatched
        // once even when the Host refuses it (there is no retry behind the
        // answer), the refusal is the result the store renders, and a draft the
        // user wrote while the question was on screen survives - the send's
        // cleanup owns only the line it sent.
        let faultTransport = RecordingTransport()
        let gateJ = FullAccessGate()
        guard let rowJ = gateJ.request(.command(composer(draft: "/permission danger-full-access"), permissionRow)) else { return assert(false, "the request opens the question") }
        let faultOutcome = await answer(gateJ, rowJ.id, live: live(), sent: faultTransport)
        assert(faultOutcome == .dispatched && faultTransport.lines == [FullAccessPolicy.commandLine],
               "a refused escalation is still dispatched exactly once")
        let refusal = CommandExecution(json(#"{"commandId":"c1","result":{"kind":"error","text":"unknown preset \"danger-full-access\""}}"#))
        assert(refusal.result.isError && refusal.result.text == "unknown preset \"danger-full-access\"",
               "the refusal is the Host's own text, which the store surfaces")
        var drafts = ComposerDrafts()
        drafts.write("/permission danger-full-access", for: "s1")
        let sending = composer(draft: "/permission danger-full-access", version: drafts.version(of: "s1"))
        drafts.write("a new draft the user owns", for: "s1")
        let kept = drafts.applySent(sending, liveSession: "s1", liveDraft: "a new draft the user owns")
        assert(kept == ComposerDrafts.SendOutcome(), "a draft written after the send is not erased")
        assert(drafts.lines["s1"] == "a new draft the user owns", "the new draft survives the cleanup and the persisted table")
        // The untouched case still clears exactly what went out.
        var untouched = ComposerDrafts()
        untouched.write("/permission danger-full-access", for: "s1")
        let same = composer(draft: "/permission danger-full-access", version: untouched.version(of: "s1"))
        assert(untouched.applySent(same, liveSession: "s1", liveDraft: "/permission danger-full-access")
               == ComposerDrafts.SendOutcome(liveDraft: "", forgotSavedLine: true))
        assert(untouched.lines["s1"] == "", "the sent line is still cleared when the user did not write again")
        print("PASS: a host fault dispatches once and a new draft survives")
    }
}
