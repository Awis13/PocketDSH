import Foundation
@main struct LiveTurnStreamCheck {
    static func main() async throws {
        let log = try String(contentsOfFile: NSHomeDirectory() + "/.dsh/web.stdout.log", encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: "http://127\\.0\\.0\\.1:3080/\\?token=[^\\s\\u001b]+")
        guard let match = pattern.matches(in: log, range: NSRange(log.startIndex..., in: log)).last, let range = Range(match.range, in: log) else { fatalError("No login URL") }
        let (base, token) = try HarnessAPI.parse(String(log[range]))
        let api = HarnessAPI(base: base); try await api.login(token: token!)
        let items = try await api.rpc("session/list", args: ["_request": .object([:])])["items"].array
        guard let session = items.first(where: { HarnessSession(raw: $0).title == "Model selection check" }) else { fatalError("Test session missing") }
        let sid = session["sessionId"].string
        let socket = api.socket(); defer { socket.cancel(with: .goingAway, reason: nil) }
        let frame: JSON = .object(["type": .string("open"), "streamId": .string("turn-watch"), "endpoint": .string("session/follow"), "payload": .object(["args": .object(["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(sid)]), "maxMessages": .number(100)])])])])
        try await socket.send(.string(String(decoding: JSONEncoder().encode(frame), as: UTF8.self)))
        let message = try await socket.receive()
        let data: Data
        switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: fatalError() }
        let result = try JSONDecoder().decode(JSON.self, from: data)
        guard result["value"]["type"].string == "snapshot" else { fatalError("Expected authenticated snapshot") }
        let events = result["value"]["records"].array.map { $0["event"] }
        guard let submitted = events.first(where: { $0["type"].string == "user/message" && !$0["data"]["source"]["rpcId"].string.isEmpty }) else { fatalError("No RPC message") }
        var state = TurnNotificationState(requestID: submitted["data"]["source"]["rpcId"].string)
        let outcomes = events.compactMap { state.consume($0) }
        guard outcomes.count == 1 else { fatalError("Expected exactly one outcome") }
        print("PASS: independent authenticated follow stream, real durable RPC correlation, exactly one turn outcome (\(outcomes[0]))")
    }
}
