import Foundation

/// Opt-in check against the isolated host created by probe-native-queue.py.
/// It speaks the real Shared/NativeWire.swift contract and drives the durable
/// queue-control receipts through a host restart. A failure is fatal: the
/// probe turns a non-zero exit into a hard test failure.
@main struct NativeQueueReceiptChecks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let phase = CommandLine.arguments[2]
        let config = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: root.appendingPathComponent("connection.json")))
        let value: @Sendable (String) -> String = { key in
            guard let found = config[key] else { fatalError("Missing config key: " + key) }
            return found
        }
        var request = URLRequest(url: URL(string: value("endpoint"))!)
        request.setValue("Bearer " + value("token"), forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request); socket.resume()
        let timeout = Task { try? await Task.sleep(for: .seconds(45)); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
        defer { timeout.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        let client = Client(socket: socket)
        if phase == "live" { try await client.live(value) } else { try await client.replay(value) }
    }
}

/// A tiny synchronous request/response helper over one WebSocket. Unrelated
/// events are dropped, so a stale snapshot can never satisfy the next wait.
final class Client {
    private let socket: URLSessionWebSocketTask
    init(socket: URLSessionWebSocketTask) { self.socket = socket }

    func send(_ command: NativeCommand) async throws {
        try await socket.send(.data(JSONEncoder().encode(command)))
    }
    func next() async throws -> NativeEvent {
        let incoming = try await socket.receive()
        let bytes: Data
        switch incoming {
        case .data(let data): bytes = data
        case .string(let text): bytes = Data(text.utf8)
        @unknown default: fatalError("Unsupported WebSocket frame")
        }
        return try JSONDecoder().decode(NativeEvent.self, from: bytes)
    }
    /// Reads until `end` matches. An unmatched host error is a hard failure so a
    /// regression surfaces as an assertion, not a hang.
    @discardableResult func wait(_ end: (NativeEvent) -> Bool) async throws -> NativeEvent {
        while true {
            let event = try await next()
            if end(event) { return event }
            if event.op == "error" { fatalError("Unexpected host error: " + (event.text ?? "")) }
        }
    }
    func open(_ session: String) async throws {
        try await send(NativeCommand(op: "open", session: session))
        try await wait { $0.op == "synced" }
    }
    func prompt(session: String, id: String, text: String, mode: String? = nil) async throws {
        try await send(NativeCommand(op: "prompt", session: session, id: id, text: text, mode: mode))
        try await wait { $0.op == "accepted" && $0.id == id }
    }
    /// Sends one queue control and returns the terminal receipt event. An error
    /// is returned to the caller rather than treated as a host-wide failure.
    func queue(session: String, requestID: String, action: String, itemID: String, text: String? = nil) async throws -> NativeEvent {
        try await send(NativeCommand(op: "queue", session: session, id: requestID, text: text, action: action, itemID: itemID))
        return try await wait { ["queueAccepted", "queueRejected", "error"].contains($0.op) }
    }
    /// Authoritative current queue snapshot. The status op recomputes it from the
    /// durable inbox, so it cannot be a stale attach copy.
    func currentQueue(session: String) async throws -> NativeQueueInfo {
        try await send(NativeCommand(op: "status", session: session))
        let event = try await wait { $0.op == "queue" }
        guard let queue = event.queue else { fatalError("Status did not carry a queue snapshot") }
        return queue
    }

    private func preview(_ queue: NativeQueueInfo, _ itemID: String) -> String? {
        queue.items.first { $0.id == itemID }?.preview
    }
    private func requireAccepted(_ event: NativeEvent, _ label: String) {
        precondition(event.op == "queueAccepted", label + " expected accepted, saw " + event.op)
    }
    private func requireRejected(_ event: NativeEvent, _ code: String, _ label: String) {
        precondition(event.op == "queueRejected" && event.text == code,
                     label + " expected rejected " + code + ", saw " + event.op + " " + (event.text ?? ""))
    }

    func live(_ v: (String) -> String) async throws {
        try await open(v("s1"))
        // Hold one turn open so steering is available while these controls run.
        try await prompt(session: v("s1"), id: v("reqPrompt"), text: "hold the turn")
        try await wait { $0.op == "stage" && $0.stage == "requesting" }

        try await prompt(session: v("s1"), id: v("itemEdit"), text: "edit target", mode: "queue")
        try await prompt(session: v("s1"), id: v("itemRemove"), text: "remove target", mode: "queue")
        try await prompt(session: v("s1"), id: v("itemSteer"), text: "steer target", mode: "queue")

        // Edit A then B under distinct request IDs.
        requireAccepted(try await queue(session: v("s1"), requestID: v("reqEditA"), action: "edit", itemID: v("itemEdit"), text: v("editA")), "edit A")
        requireAccepted(try await queue(session: v("s1"), requestID: v("reqEditB"), action: "edit", itemID: v("itemEdit"), text: v("editB")), "edit B")
        let afterEditB = try await currentQueue(session: v("s1"))
        precondition(preview(afterEditB, v("itemEdit")) == v("editB"))

        // Exact retry A replays its receipt and must not roll text back to A.
        requireAccepted(try await queue(session: v("s1"), requestID: v("reqEditA"), action: "edit", itemID: v("itemEdit"), text: v("editA")), "retry A")
        let afterRetryInProcess = try await currentQueue(session: v("s1"))
        precondition(preview(afterRetryInProcess, v("itemEdit")) == v("editB"),
                     "An exact retry of A must not revert the later edit B")

        // Same request ID with changed text is refused and mutates nothing.
        let conflict = try await queue(session: v("s1"), requestID: v("reqEditA"), action: "edit", itemID: v("itemEdit"), text: v("editA") + "-changed")
        precondition(conflict.op == "error", "A changed fingerprint under the same request ID must error")
        let afterConflict = try await currentQueue(session: v("s1"))
        precondition(preview(afterConflict, v("itemEdit")) == v("editB"),
                     "A refused conflict must not mutate the queue")

        // Accepted remove and steer, plus a durable rejected outcome.
        requireAccepted(try await queue(session: v("s1"), requestID: v("reqRemove"), action: "remove", itemID: v("itemRemove")), "remove")
        requireAccepted(try await queue(session: v("s1"), requestID: v("reqSteer"), action: "steer", itemID: v("itemSteer")), "steer")
        requireRejected(try await queue(session: v("s1"), requestID: v("reqReject"), action: "steer", itemID: v("itemMissing")),
                        "queue-item-not-found", "rejected steer")

        // Session isolation: this request ID already exists in s1 with another
        // fingerprint; s2 must treat it as its own, not a global conflict.
        try await open(v("s2"))
        requireRejected(try await queue(session: v("s2"), requestID: v("reqEditA"), action: "edit", itemID: v("itemS2"), text: v("editA") + "-s2"),
                        "queue-item-not-found", "isolated s2 request")
        print("PASS native queue receipts live: edit A/B, conflict refusal, remove/steer, rejected outcome, session isolation")
    }

    func replay(_ v: (String) -> String) async throws {
        try await open(v("s1"))

        // Retry A after restart returns its original receipt, but B stays B.
        requireAccepted(try await queue(session: v("s1"), requestID: v("reqEditA"), action: "edit", itemID: v("itemEdit"), text: v("editA")), "replay A")
        let afterReplayEditA = try await currentQueue(session: v("s1"))
        precondition(preview(afterReplayEditA, v("itemEdit")) == v("editB"),
                     "After restart, retry A must return its receipt and leave B intact")

        // Changed fingerprint under the same request ID errors with no mutation.
        let conflict = try await queue(session: v("s1"), requestID: v("reqEditA"), action: "edit", itemID: v("itemEdit"), text: v("editA") + "-changed")
        precondition(conflict.op == "error", "Changed fingerprint after restart must error")
        let afterReplayConflict = try await currentQueue(session: v("s1"))
        precondition(preview(afterReplayConflict, v("itemEdit")) == v("editB"))

        // Accepted remove and steer replay exactly.
        requireAccepted(try await queue(session: v("s1"), requestID: v("reqRemove"), action: "remove", itemID: v("itemRemove")), "replay remove")
        let afterReplayRemove = try await currentQueue(session: v("s1"))
        precondition(afterReplayRemove.items.contains { $0.id == v("itemRemove") } == false)
        requireAccepted(try await queue(session: v("s1"), requestID: v("reqSteer"), action: "steer", itemID: v("itemSteer")), "replay steer")
        let afterReplaySteer = try await currentQueue(session: v("s1"))
        precondition(afterReplaySteer.items.first { $0.id == v("itemSteer") }?.placement == NativeQueueItem.steering)

        // Rejected stays rejected after the turn dropped to idle. Old code would
        // re-evaluate to steer-unavailable here.
        requireRejected(try await queue(session: v("s1"), requestID: v("reqReject"), action: "steer", itemID: v("itemMissing")),
                        "queue-item-not-found", "replay rejected")

        // s2 keeps its own receipt for the shared request ID.
        try await open(v("s2"))
        requireRejected(try await queue(session: v("s2"), requestID: v("reqEditA"), action: "edit", itemID: v("itemS2"), text: v("editA") + "-s2"),
                        "queue-item-not-found", "replayed s2 request")
        print("PASS native queue receipts replay: exact retry keeps B, conflict refused, accepted/rejected replay, session isolation")
    }
}