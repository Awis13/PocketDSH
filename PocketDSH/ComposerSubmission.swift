import Foundation

// The composer's send path, frozen into values.
//
// The composer stays editable while a send is in flight - the command catalog's
// warmup alone can take a whole round trip - so every step of one send action
// must read the state the user sent, never the live composer. This file holds
// that snapshot and the decisions taken on it, as plain values the offline
// checks compile and drive directly: `PocketStore` itself is compiled by no
// gate (`scripts/check.sh` and `check-protocol.sh` compile the ported value
// files - this one included - but not the store), so a rule that lives only in
// the store can be found by reading alone.

/// One composer send action, frozen on the main actor by the action that owns
/// it - the send button, the keyboard shortcut, or a palette row - before that
/// action suspends for the first time.
///
/// Why the whole value and not a live read: `executeCommand` waits for the
/// session's command catalog (`ensureReadyAsync`) and `submit` waits for the
/// prompt RPC, and both waits are suspensions in which the user keeps typing
/// and attaching. A dispatch that re-read `draft`/`images` after its wait sends
/// content the user never confirmed: an unknown `/command` typed and then
/// replaced would be sent as the replacement text, and a command would ride
/// with attachments that were not there when it was submitted.
///
/// The connection identity is part of the snapshot. `endpoint` alone cannot
/// express a reconnect to the same Host with the same session selected, so the
/// snapshot also carries the command directory's `catalogGeneration` - the value
/// a teardown rotates (`CommandDirectory.removeAll`) - and a send that outlives
/// its connection is dropped instead of being issued against the next one.
struct ComposerSubmission {
    /// The composer draft exactly as typed, trimming not applied.
    var draft: String
    var images: [OutgoingImage]
    var sessionID: String
    var endpoint: String
    var catalogGeneration: Int

    /// The text this action sends: the draft without surrounding whitespace,
    /// which is what the reference trims before `matchEnter` and before
    /// `session/prompt`.
    var text: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var imageIDs: [UUID] { images.map(\.id) }
    /// The draft-store key of the composer this snapshot came from.
    var imageDraftKey: String { endpoint + "|" + sessionID }

    /// Whether this snapshot still names the live session and connection. Every
    /// step after a suspension re-checks it, so a send never lands on a session
    /// or a connection the user switched to while it was waiting.
    func stillApplies(sessionID: String?, endpoint: String, catalogGeneration: Int) -> Bool {
        sessionID == self.sessionID && endpoint == self.endpoint && catalogGeneration == self.catalogGeneration
    }

    /// Whether an unconfirmed request is a retry of this same submission: same
    /// session, same text, same attachments, so a retry keeps its request id
    /// instead of minting a second one. Content the user changed is a new
    /// request, exactly as before the snapshot existed. The parameter is the
    /// shape of the store's `pendingRequest`.
    func isRetry(of request: (id: String, text: String, session: String, imageIDs: [UUID])) -> Bool {
        request.session == sessionID && request.text == text && request.imageIDs == imageIDs
    }

    /// Whether a draft the composer (or its saved session table) holds is the
    /// content this snapshot sent. Surrounding whitespace does not make it a
    /// different draft: the reference trims the line it submits, so a composer
    /// holding "  /compact  " holds the line that went out.
    func isSentDraft(_ current: String) -> Bool {
        current.trimmingCharacters(in: .whitespacesAndNewlines) == text
    }

    /// The draft the composer keeps after this snapshot was actually sent: the
    /// text that went out is cleared, and anything the user typed meanwhile -
    /// including the same text retyped as a new draft - is not this action's to
    /// erase.
    func draftAfterSend(_ current: String) -> String {
        isSentDraft(current) ? "" : current
    }

    /// The attachments the composer keeps after this snapshot was sent: only
    /// the ones that went with it are dropped, so anything attached meanwhile
    /// stays for the next message.
    func imagesAfterSend(_ current: [OutgoingImage]) -> [OutgoingImage] {
        let sent = Set(imageIDs)
        return current.filter { !sent.contains($0.id) }
    }
}

/// What one frozen command action does once its session's catalog is servable.
enum CommandDispatch: Equatable {
    /// The catalog claims the line, so it goes to `commands/execute` with this
    /// descriptor. The snapshot's attachments ride along only when the command
    /// declares attachment input; that check happens before this case returns.
    case execute(CommandDescriptor)
    /// The catalog does not claim the line: an unknown name, or trailing
    /// arguments on a command that declares no input line. The ordinary message
    /// path owns it, with the snapshot's own text and attachments.
    case message
    /// A command that declares no attachment input cannot be submitted with
    /// the snapshot's attachments. Nothing is sent, the message is what the
    /// composer reports, and the draft and attachments stay for correction.
    case refusesAttachments(String)
}

/// Decide one frozen command line against a servable catalog - the reference
/// `matchEnter` claim rule (`commandClaimsLine`), with the attachment refusal
/// the reference also applies before dispatch (`desc.input.attachments !==
/// true`, dsh-client-ui-commands client.js). Pure: the store runs the catalog
/// wait itself and hands the outcome here, so the offline checks drive exactly
/// the decision production takes, not a copy of it.
func resolveCommandDispatch(_ snapshot: ComposerSubmission, descriptors: [CommandDescriptor]) -> CommandDispatch {
    let text = snapshot.text
    guard let name = parseCommand(text)?.name, !name.isEmpty else { return .message }
    let resolved = descriptors.first { $0.name == name }
    guard commandClaimsLine(text, descriptor: resolved), let descriptor = resolved else { return .message }
    guard snapshot.images.isEmpty || commandAdmitsAttachments(descriptor) else {
        return .refusesAttachments("The /\(descriptor.name) command does not accept attachments. Remove them first.")
    }
    return .execute(descriptor)
}

/// The `session/prompt` content array of one frozen submission: the text part
/// when there is text, then the image parts in composer order. This is the
/// ordinary message path's payload, including when a command line fell through
/// to it.
func promptContent(_ snapshot: ComposerSubmission) -> [JSON] {
    let text = snapshot.text
    return (text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]) + snapshot.images.map(\.part)
}

/// The `commands/execute` attachments of one frozen submission, or nil when one
/// of them has no valid union arm at all. The caller refuses the submission
/// instead of staging a receipt-less file the Host would reject.
func submissionAttachments(_ images: [OutgoingImage]) -> [JSON]? {
    var submitted: [JSON] = []
    for image in images {
        guard let wire = CommandSubmitAttachment(image.part).wire else { return nil }
        submitted.append(wire)
    }
    return submitted
}
