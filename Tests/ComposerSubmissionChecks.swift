import Foundation

// DSH-REVIEW-2: one composer send action must send the state the user sent.
//
// Every assertion below drives the production values themselves
// (`ComposerSubmission`, `resolveCommandDispatch`, `promptContent`,
// `submissionAttachments`) - never a copy of the algorithm - through the
// sequence a slow catalog pull creates: the action freezes the composer, the
// user keeps editing while the pull is in flight, the catalog answers, and the
// dispatch that follows decides what goes on the wire and what the composer
// keeps. `PocketStore` is outside every offline gate, so the rules that used to
// live only inside it are asserted here on the code the store actually calls.

@main struct ComposerSubmissionChecks {
    static let host = "https://dsn.example"
    static func json(_ s: String) -> JSON { try! JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }

    /// A catalog row: `input` nil means the command declares no input line,
    /// otherwise the row declares one and optionally admits attachments.
    static func descriptor(_ name: String, input: Bool = false, attachments: Bool? = nil) -> CommandDescriptor {
        guard input else { return CommandDescriptor(json(#"{"name":"\#(name)","description":"d"}"#)) }
        let flag = attachments.map { ",\"attachments\":\($0)" } ?? ""
        return CommandDescriptor(json(#"{"name":"\#(name)","description":"d","input":{"hint":"h"\#(flag)}}"#))
    }
    static func image(_ name: String) -> OutgoingImage {
        OutgoingImage(id: UUID(), data: Data(name.utf8), mediaType: "image/jpeg", name: name)
    }
    static func composer(draft: String, images: [OutgoingImage] = [], session: String = "s1",
                         endpoint: String = host, generation: Int = 1) -> ComposerSubmission {
        ComposerSubmission(draft: draft, images: images, sessionID: session, endpoint: endpoint, catalogGeneration: generation)
    }
    /// The text part of a `session/prompt` content array, or nil for an
    /// image-only submission.
    static func text(of content: [JSON]) -> String? { content.first { $0["type"].string == "text" }?["text"].string }
    static func imageNames(of content: [JSON]) -> [String] {
        content.filter { $0["type"].string == "image" }.map { $0["name"].string }
    }

    static func main() {
        let a = image("a.jpg"), b = image("b.jpg")

        // 1. Unknown command, delayed catalog: the user sends "/notacommand"
        // with attachment a, keeps typing while the pull flies, and the
        // servable catalog does not claim the line. The ordinary message path
        // must carry the frozen line and the frozen attachment - the text typed
        // during the wait is the next message, not this one - and the cleanup
        // must leave that new draft and the new attachment in the composer.
        let unknown = composer(draft: "/notacommand", images: [a])
        assert(unknown.text == "/notacommand" && unknown.imageIDs == [a.id])
        let liveDraft = "a completely new draft", liveImages = [b]
        switch resolveCommandDispatch(unknown, descriptors: [descriptor("goal"), descriptor("compact", input: true, attachments: true)]) {
        case .message:
            let content = promptContent(unknown)
            assert(text(of: content) == "/notacommand", "the fallback sends the frozen line, not the new draft")
            assert(imageNames(of: content) == ["a.jpg"], "the fallback sends the frozen attachment, not the new one")
        default: assert(false, "an unknown name must fall through to the message path")
        }
        assert(unknown.draftAfterSend(liveDraft) == "a completely new draft", "the draft typed during the wait is not erased by the sent command")
        assert(unknown.imagesAfterSend(liveImages) == [b], "the attachment added during the wait stays")
        print("PASS: unknown command sends the frozen draft and attachments and keeps the new ones")

        // 2. A claimed command with an attachment swapped while the pull flew:
        // the execute RPC carries the frozen attachment only, and the swap
        // survives in the composer.
        let claimed = composer(draft: "/compact", images: [a])
        guard case .execute(let claimedRow) = resolveCommandDispatch(claimed, descriptors: [descriptor("compact", input: true, attachments: true)]) else {
            return assert(false, "a declared command must claim its line")
        }
        assert(claimedRow.name == "compact" && commandAdmitsAttachments(claimedRow))
        let executeArgs = commandExecuteArguments(agentId: claimed.sessionID, line: claimed.text,
                                                  submittedAttachments: submissionAttachments(claimed.images)!)
        let submitted = executeArgs["submittedAttachments"]!.array
        assert(submitted.count == 1 && submitted[0]["name"].string == "a.jpg", "commands/execute carries the frozen attachment")
        assert(submitted[0]["data"].string == a.data.base64EncodedString() && executeArgs["line"]!.string == "/compact")
        assert(claimed.draftAfterSend("") == "" && claimed.imagesAfterSend([b]) == [b], "the swapped attachment is not dropped")
        print("PASS: claimed command sends the frozen attachment and keeps the replacement")

        // 3. The draft is not the send's to erase once the user typed a new one
        // during the wait, on the command path as well.
        assert(claimed.draftAfterSend("something else") == "something else", "a new draft survives a successful command")
        assert(claimed.draftAfterSend("  /compact  ") == "", "a draft that differs only in whitespace is the sent content")
        let imageOnly = composer(draft: "   ", images: [a])
        assert(imageOnly.draftAfterSend("   ") == "" && imageOnly.text.isEmpty)
        assert(promptContent(imageOnly).count == 1 && imageNames(of: promptContent(imageOnly)) == ["a.jpg"])
        print("PASS: cleanup clears only what was sent")

        // 4. Attachment refusal: a command that declares no attachment input is
        // not submitted with the snapshot's attachments, nothing is sent, and
        // the draft and attachments stay for correction.
        let withImage = composer(draft: "/goal", images: [a])
        switch resolveCommandDispatch(withImage, descriptors: [descriptor("goal")]) {
        case .refusesAttachments(let message):
            assert(message == "The /goal command does not accept attachments. Remove them first.", "the refusal names the command")
            // The refusal arm sends nothing and hands nothing to a cleanup: the
            // composer still holds exactly what the user typed.
            assert(withImage.draft == "/goal" && withImage.imageIDs == [a.id], "a refusal leaves the draft and the attachments in place")
        default: assert(false, "a command without attachment input must refuse an attachment-carrying submission")
        }
        assert(resolveCommandDispatch(composer(draft: "/goal"), descriptors: [descriptor("goal")]) == .execute(descriptor("goal")),
               "the same command stays executable without attachments")
        print("PASS: a command without attachment input refuses instead of sending")

        // 5. Trailing arguments on a command that declares no input line are
        // not claimed (the reference matchEnter rule), and they fall through
        // with the frozen line - not with a stale live draft.
        let trailing = composer(draft: "/goal now")
        assert(resolveCommandDispatch(trailing, descriptors: [descriptor("goal")]) == .message)
        assert(resolveCommandDispatch(composer(draft: "/compact now"), descriptors: [descriptor("compact", input: true)]) == .execute(descriptor("compact", input: true)))
        print("PASS: claim rule keeps unknown and argument-less lines on the message path")

        // 6. Connection identity: a send that outlives its session or its
        // connection is dropped, including a reconnect to the same Host with
        // the same session selected - the case endpoint and session id cannot
        // express, which is why the snapshot carries the catalog generation.
        let frozen = composer(draft: "/compact", session: "s1", generation: 7)
        assert(frozen.stillApplies(sessionID: "s1", endpoint: host, catalogGeneration: 7))
        assert(!frozen.stillApplies(sessionID: "s2", endpoint: host, catalogGeneration: 7), "a session switch cancels the send")
        assert(!frozen.stillApplies(sessionID: nil, endpoint: host, catalogGeneration: 7), "a disconnect cancels the send")
        assert(!frozen.stillApplies(sessionID: "s1", endpoint: "https://other.example", catalogGeneration: 7), "another Host cancels the send")
        assert(!frozen.stillApplies(sessionID: "s1", endpoint: host, catalogGeneration: 8), "a torn-down connection cancels the send")
        print("PASS: a frozen action is bound to its session and connection generation")

        // 7. Retry identity is unchanged: an unconfirmed request keeps its id
        // only for the same content, and an edit made during the wait is a new
        // request rather than a retry of the pending one.
        let pending = (id: UUID().uuidString, text: "/goal", session: "s1", imageIDs: [a.id])
        assert(composer(draft: "  /goal  ", images: [a]).isRetry(of: pending), "the same content is the same request")
        assert(!composer(draft: "/goal", images: [a, b]).isRetry(of: pending), "another attachment is a new request")
        assert(!composer(draft: "/goals", images: [a]).isRetry(of: pending), "an edited line is a new request")
        assert(!composer(draft: "/goal", images: [a], session: "s2").isRetry(of: pending), "another session is a new request")
        print("PASS: retry identity follows the frozen content")

        // 8. The execute argument builder refuses an attachment with no valid
        // union arm instead of staging a receipt-less file.
        let invalid = OutgoingImage(id: UUID(), data: Data(), mediaType: "image/jpeg", name: "empty.jpg")
        assert(submissionAttachments([invalid]) == nil && submissionAttachments([])?.isEmpty == true)
        assert(submissionAttachments([a])?.count == 1 && composer(draft: "/x").imageDraftKey == host + "|s1")
        print("PASS: submission attachments validate their wire union")
    }
}
