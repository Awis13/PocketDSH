import Foundation

@main struct NativeQueueChecks {
    static func main() throws {
        // Optional mode is back-compatible: an old command without mode decodes to nil.
        let legacy = try JSONDecoder().decode(NativeCommand.self, from: Data(#"{"op":"prompt","id":"r1","text":"hi"}"#.utf8))
        precondition(legacy.mode == nil && legacy.action == nil && legacy.itemID == nil)
        let command = NativeCommand(op: "queue", session: "s", id: "req", text: "new text", mode: "steer", action: "edit", itemID: "item-1")
        let decoded = try JSONDecoder().decode(NativeCommand.self, from: JSONEncoder().encode(command))
        precondition(decoded.mode == "steer" && decoded.action == "edit" && decoded.itemID == "item-1")
        let encoded = String(decoding: try JSONEncoder().encode(NativeCommand(op: "prompt", id: "r")), as: UTF8.self)
        precondition(!encoded.contains("mode") && !encoded.contains("action") && !encoded.contains("itemID"),
                     "Absent optional fields must stay absent on the wire")

        precondition(NativeQueueInfo.capability == "session.queue.v1")
        // A queue snapshot round-trips losslessly while envelope-level future
        // fields, including large integers, survive replay.
        let fixture = Data(#"{"op":"queue","session":"s","sequence":4,"queue":{"items":[{"id":"a","preview":"first","placement":"queued","truncated":false},{"id":"b","preview":"second","placement":"steering","truncated":true}],"omitted":3},"futureEnvelope":{"n":9007199254740993,"nested":[true,null,"x"]}}"#.utf8)
        let event = try JSONDecoder().decode(NativeEvent.self, from: fixture)
        let info = event.queue!
        precondition(info.items.count == 2 && info.omitted == 3 && info.count == 5)
        precondition(info.items[0].valid && !info.items[0].isSteering && info.items[0].placementLabel == "Runs after the current turn")
        precondition(info.items[1].valid && info.items[1].isSteering && info.items[1].placementLabel == "Steers the current turn")
        let reencoded = try JSONEncoder().encode(event)
        let roundtrip = try JSONDecoder().decode(NativeEvent.self, from: reencoded)
        precondition(roundtrip.queue == info)
        let originalJSON = try JSONDecoder().decode(NativeJSON.self, from: fixture)
        let roundtripJSON = try JSONDecoder().decode(NativeJSON.self, from: reencoded)
        precondition(roundtripJSON == originalJSON,
                     "Queue snapshot and future envelope fields must round-trip losslessly")

        // A malformed queue block is preserved as an extension rather than
        // disconnecting the client, and invalid placements are never selectable.
        let malformed = try JSONDecoder().decode(NativeEvent.self, from: Data(#"{"op":"queue","queue":"future-format"}"#.utf8))
        precondition(malformed.queue == nil && malformed.extraFields["queue"] != nil)
        precondition(!NativeQueueItem(id: "", preview: "", placement: NativeQueueItem.queued, truncated: false).valid)
        precondition(!NativeQueueItem(id: "x", preview: "", placement: "later", truncated: false).valid)
        precondition(NativeQueueInfo.rejectionDetail("queue-item-not-found") != NativeQueueInfo.rejectionDetail("steer-unavailable"))

        // An acknowledgement for the user's own submission must survive switching
        // sessions, or `nativeSubmission`/`pendingRequest` would never clear and
        // every later send would stay blocked. Error/rejection and transcript
        // events remain scoped to the selected session.
        precondition(NativeEvent(op: "accepted", session: "A").deliversToSelection("B"),
                     "A submission ACK must be processed even after switching sessions")
        precondition(!NativeEvent(op: "error", session: "A").deliversToSelection("B"))
        precondition(!NativeEvent(op: "queueRejected", session: "A").deliversToSelection("B"))
        precondition(!NativeEvent(op: "user", session: "A").deliversToSelection("B"))
        precondition(NativeEvent(op: "accepted", session: "A").deliversToSelection("A"))
        precondition(NativeEvent(op: "error").deliversToSelection("B"),
                     "A session-less error is host-wide and still applied")
        print("PASS native selection scope: ACK clears across sessions, errors stay scoped")
        print("PASS native queue wire: optional mode, edit/remove/steer fields, bounded snapshot, capability and lossless future fields")
    }
}
