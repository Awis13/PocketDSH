import Foundation

// DSH-INTEGRATION-1: the carrier's failure and ready edges drop a pending
// full-access confirmation, driven through the production seam the store uses.
//
// The acceptance gap this closes: FullAccessConfirmationChecks and
// HarnessStreamChecks were byte-identical to the accepted source heads, and
// neither ever executed the combined carrier -> confirmation path together -
// "existing isolated gate tests don't execute the newly combined carrier ->
// pending-confirmation invalidation." These checks do, in one file:
//
//   1. a pending escalation asked while the carrier connects - the socket fails
//      and the carrier will not reconnect - the seam drops the pending and a late
//      still-applies confirm dispatches nothing;
//   2. a pending escalation asked while the carrier is between a failed attempt
//      and its reconnect - the ready of the new attempt drops it, so a late
//      confirm dispatches nothing;
//   3. the routing decision - the escalation to the gate, the compact line to a
//      frozen server dispatch - counted with the frozen dispatch and the draft.
//
// Every assertion drives the production values the store itself uses - the real
// `RemoteStreamConnection.run` loop, the production `ConfirmationLifecycle` seam
// wired to a real `FullAccessGate`, and `resolveCommandDispatch` - never a copy
// of them, so "the carrier dropped the question" is proved on the same objects
// the store drives.

/// The carrier socket the offline checks substitute: it records the open frames
/// the real carrier loop sends, so a body that never ran is not mistaken for a
/// ready one.
@MainActor
final class ProbeTransport: RemoteStreamTransport {
    private(set) var frames: [JSON] = []
    func sendFrame(_ frame: JSON) async throws { frames.append(frame) }
    func ping() async throws {}
}

/// One parked continuation: the carrier loop's backoff `sleep` parks on it, so the
/// test can set a pending confirmation exactly while the carrier sits between a
/// failed attempt and its reconnect - the window the ready edge has to cover.
@MainActor
final class Park {
    private(set) var isParked = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        isParked = true
        await withCheckedContinuation { self.continuation = $0 }
    }
    func release() {
        if let continuation { continuation.resume(); self.continuation = nil }
    }
}

@main struct FullAccessCarrierLifecycleChecks {
    static let host = "https://dsn.example"
    static func json(_ s: String) -> JSON { try! JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }

    /// A catalog row: `input` nil means the command declares no input line.
    static func descriptor(_ name: String, input: Bool = false, hint: String = "<preset>", attachments: Bool? = nil) -> CommandDescriptor {
        guard input else { return CommandDescriptor(json(#"{"name":"\#(name)","description":"d"}"#)) }
        let flag = attachments.map { ",\"attachments\":\($0)" } ?? ""
        return CommandDescriptor(json(#"{"name":"\#(name)","description":"d","input":{"hint":"\#(hint)"\#(flag)}}"#))
    }
    static var permissionRow: CommandDescriptor { descriptor("permission", input: true) }
    /// The catalog a DSH session serves: the escalation plus ordinary commands.
    static var catalog: [CommandDescriptor] {
        [permissionRow, descriptor("compact", input: true, hint: "compact [reason]", attachments: true), descriptor("goal"), descriptor("help")]
    }
    static func composer(draft: String, images: [OutgoingImage] = [], session: String = "s1",
                         endpoint: String = host, generation: Int = 1, version: Int = 0) -> ComposerSubmission {
        ComposerSubmission(draft: draft, images: images, sessionID: session, endpoint: endpoint,
                           catalogGeneration: generation, draftVersion: version)
    }
    static func live(session: String? = "s1", endpoint: String = host, generation: Int = 1) -> LiveConnectionIdentity {
        LiveConnectionIdentity(sessionID: session, endpoint: endpoint, catalogGeneration: generation)
    }
    static func conversationArgs(_ sessionId: String) -> [String: JSON] {
        ["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(sessionId)]), "maxMessages": .number(50)])]
    }

    /// The store's `commands/execute` leg, recorded on the wire shape.
    @MainActor
    final class Recorder {
        private(set) var calls: [[String: JSON]] = []
        func execute(_ snapshot: ComposerSubmission, _ descriptor: CommandDescriptor) async {
            let submitted = submissionAttachments(snapshot.images) ?? []
            calls.append(commandExecuteArguments(agentId: snapshot.sessionID, line: snapshot.text, submittedAttachments: submitted))
        }
        var lines: [String] { calls.map { $0["line"]?.string ?? "" } }
    }

    /// Poll a condition until it holds, so the carrier loop and the test interleave
    /// deterministically instead of racing on a fixed delay.
    @MainActor
    static func spin(_ reached: () -> Bool) async {
        let deadline = Date().addingTimeInterval(20)
        while !reached() {
            assert(Date() < deadline, "the carrier never reached the state the test expected")
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do {
            try await failureDropsPending()
            try await readyDropsPending()
            try await routingFrozenDispatch()
            print("PASS: the carrier's failure and ready edges drop a pending confirmation")
            exit(0)
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    // (1) A pending escalation asked while the carrier connects: the socket fails
    // and the carrier will not reconnect, so the seam drops the pending and a late
    // still-applies confirm - same session, endpoint and catalog generation -
    // dispatches nothing. Sensitive to `carrierFailed`.
    @MainActor
    static func failureDropsPending() async throws {
        let carrier = RemoteStreamConnection()
        let transport = ProbeTransport()
        let gate = FullAccessGate()
        let lifecycle = ConfirmationLifecycle(gate)
        let snapshot = composer(draft: "/permission danger-full-access")
        guard let asked = gate.request(.command(snapshot, permissionRow)) else {
            return assert(false, "the escalation is pending while the carrier connects")
        }
        await carrier.run(attempts: 1, sleep: { _ in }, body: { _ in
            _ = try await carrier.subscribe(.conversation, endpoint: "session/follow", args: conversationArgs("s1"), on: transport)
            throw HarnessError(message: "the socket died before any reconnect")
        }, onAttempt: { _ in }, onFailure: { _, _ in lifecycle.carrierFailed() }, onFinish: {})
        assert(transport.frames.count == 1, "the carrier's body ran and opened its stream")
        assert(gate.pending == nil, "a carrier failure with no reconnect drops the pending confirmation")
        let recorder = Recorder()
        let outcome = await gate.confirm(id: asked.id, live: live(), busy: false,
                                         command: { await recorder.execute($0, $1) }, approval: { _ in })
        assert(outcome == .rejected && recorder.calls.isEmpty, "a late confirmation to a dead carrier dispatches nothing")
        print("PASS: a failed carrier with no reconnect drops the pending confirmation")
    }

    // (2) A pending escalation asked while the carrier is between a failed attempt
    // and its reconnect: the ready of the new attempt drops it, so a late
    // still-applies confirm dispatches nothing. Sensitive to `attemptReady`.
    @MainActor
    static func readyDropsPending() async throws {
        let carrier = RemoteStreamConnection()
        let transport = ProbeTransport()
        let gate = FullAccessGate()
        let lifecycle = ConfirmationLifecycle(gate)
        let backoff = Park()
        var pendingID: UUID?
        let run = Task {
            await carrier.run(attempts: 2, sleep: { _ in await backoff.wait() }, body: { attempt in
                _ = try await carrier.subscribe(.conversation, endpoint: "session/follow", args: conversationArgs("s1"), on: transport)
                if attempt.index == 2 { lifecycle.attemptReady() }
                if attempt.index == 1 { throw HarnessError(message: "the first attempt died") }
            }, onAttempt: { _ in }, onFailure: { _, _ in lifecycle.carrierFailed() }, onFinish: {})
        }
        await spin { backoff.isParked }
        // The user asks for full access while the carrier is reconnecting:
        pendingID = gate.request(.command(composer(draft: "/permission danger-full-access"), permissionRow))?.id
        assert(pendingID != nil, "the escalation is pending while the carrier reconnects")
        assert(gate.pending != nil, "the pending is still live in the gap between the failed attempt and its reconnect")
        // The reconnect lands: the ready of the new attempt drops the old confirmation.
        backoff.release()
        await run.value
        assert(transport.frames.count == 2, "the reconnect's attempt ran and opened its stream")
        assert(gate.pending == nil, "the ready of a new attempt drops the pending confirmation")
        let recorder = Recorder()
        let outcome = await gate.confirm(id: pendingID!, live: live(), busy: false,
                                         command: { await recorder.execute($0, $1) }, approval: { _ in })
        assert(outcome == .rejected && recorder.calls.isEmpty, "a late confirmation to a ready new attempt dispatches nothing")
        print("PASS: the ready of a new attempt drops the pending confirmation")
    }

    // (3) The routing decision and its frozen dispatch, in the same integration:
    // the escalation routes to the gate and the compact line to a frozen server
    // dispatch; cancel is nothing with the draft kept, confirm is exactly one
    // frozen dispatch with the sent line cleaned up by the send's own rule.
    @MainActor
    static func routingFrozenDispatch() async throws {
        guard case .confirmFullAccess(let escalation) = resolveCommandDispatch(composer(draft: "/permission danger-full-access"), descriptors: catalog) else {
            return assert(false, "the claimed escalation routes to the gate")
        }
        assert(escalation.name == "permission")
        guard case .execute(let compact) = resolveCommandDispatch(composer(draft: "/compact"), descriptors: catalog) else {
            return assert(false, "a bare /compact routes to a frozen server dispatch on DSH")
        }
        assert(compact.name == "compact")

        let recorder = Recorder()
        // The compact line is one frozen dispatch carrying its frozen line.
        let compactSnapshot = composer(draft: "/compact")
        await recorder.execute(compactSnapshot, compact)
        assert(recorder.calls.count == 1 && recorder.lines == ["/compact"], "the compact line is one frozen dispatch")

        // The escalation dispatches only from the gate's answer. The user's line
        // is a write, and the snapshot freezes at that write's version - the
        // store's own rule - so the send's cleanup below sees the line it sent.
        let gate = FullAccessGate()
        let line = "/permission danger-full-access"
        var drafts = ComposerDrafts()
        drafts.write(line, for: "s1")
        let snapshot = composer(draft: line, version: drafts.version(of: "s1"))
        guard let asked = gate.request(.command(snapshot, escalation)) else {
            return assert(false, "the escalation opens its confirmation")
        }
        assert(recorder.calls.count == 1, "opening the confirmation dispatches nothing")
        assert(gate.cancel(id: asked.id) && gate.pending == nil, "canceling drops the pending action")
        assert(recorder.calls.count == 1, "canceling the escalation dispatches nothing")
        assert(drafts.lines["s1"] == line, "canceling keeps the draft the user sent")
        guard let reasked = gate.request(.command(snapshot, escalation)) else {
            return assert(false, "the route is free again after the cancel")
        }
        let outcome = await gate.confirm(id: reasked.id, live: live(), busy: false,
                                         command: { await recorder.execute($0, $1) }, approval: { _ in })
        assert(outcome == .dispatched && recorder.calls.count == 2 && recorder.lines == ["/compact", line],
               "confirming dispatches exactly one frozen line to the frozen session")
        let sent = drafts.applySent(snapshot, liveSession: "s1", liveDraft: line)
        assert(sent.forgotSavedLine && sent.liveDraft == "" && drafts.lines["s1"] == "",
               "the confirmed send clears only the line it sent")
        print("PASS: routing reaches the gate and the frozen dispatch, with cancel/confirm counts and the draft")
    }
}
