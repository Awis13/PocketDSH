import Foundation
@main struct TurnNotificationCheck {
    static func main() {
        func event(_ seq: Int, _ type: String, _ data: [String: JSON]) -> JSON {
            .object(["seq": .number(Double(seq)), "type": .string(type), "data": .object(data)])
        }
        let accepted = event(4, "user/message", ["source": .object(["rpcId": .string("mine")])])
        var state = TurnNotificationState(requestID: "mine")
        assert(state.consume(event(1, "turn/end", ["reason": .object(["kind": .string("completed")])])) == nil)
        assert(state.consume(event(2, "user/message", ["source": .object(["rpcId": .string("other")])])) == nil)
        assert(!state.accepted)
        assert(state.consume(event(3, "turn/end", ["reason": .object(["kind": .string("error")])])) == nil)
        assert(state.consume(accepted) == nil && state.accepted)
        assert(state.consume(event(3, "turn/end", ["reason": .object(["kind": .string("completed")])])) == nil)
        assert(state.consume(event(5, "assistant/message", [:])) == nil)
        assert(state.consume(event(6, "turn/end", ["reason": .object(["kind": .string("completed")])])) == "completed")
        assert(state.consume(event(7, "turn/end", ["reason": .object(["kind": .string("error")])])) == nil)
        for reason in ["blocked", "error", "aborted", "interrupted", "max-tokens"] {
            var other = TurnNotificationState(requestID: "mine")
            _ = other.consume(accepted)
            assert(other.consume(event(5, "turn/end", ["reason": .object(["kind": .string(reason)])])) == reason)
        }
        print("PASS: exact request matching, old-turn exclusion, replay deduplication, durable completion and stop reasons")
    }
}
