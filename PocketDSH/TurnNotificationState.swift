import Foundation

/// Only a durable end after the exact submitted message can complete this watch.
struct TurnNotificationState {
    let requestID: String
    var cursor = -1
    var accepted = false
    var finished = false
    mutating func consume(_ event: JSON) -> String? {
        let seq = event["seq"].int
        guard !finished, seq > cursor else { return nil }
        cursor = seq
        if event["type"].string == "user/message", event["data"]["source"]["rpcId"].string == requestID { accepted = true }
        guard accepted, event["type"].string == "turn/end" else { return nil }
        finished = true
        return event["data"]["reason"]["kind"].string
    }
}
