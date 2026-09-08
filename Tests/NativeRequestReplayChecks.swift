import Foundation

/// Opt-in check against the isolated host created by probe-native-request-replay.py.
@main struct NativeRequestReplayChecks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let phase = CommandLine.arguments[2]
        let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("connection.json")))
        var request = URLRequest(url: URL(string: config["endpoint"]!)!)
        request.setValue("Bearer " + config["token"]!, forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request); socket.resume()
        let timeout = Task { try? await Task.sleep(for: .seconds(30)); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
        defer { timeout.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        func send(_ c: NativeCommand) async throws { try await socket.send(.data(JSONEncoder().encode(c))) }
        func until(_ end: (NativeEvent) -> Bool) async throws -> [NativeEvent] {
            var events: [NativeEvent] = []
            while true {
                let incoming = try await socket.receive()
                let bytes: Data
                switch incoming { case .data(let d): bytes = d; case .string(let s): bytes = Data(s.utf8); @unknown default: fatalError() }
                let event = try JSONDecoder().decode(NativeEvent.self, from: bytes)
                precondition(event.op != "error", event.text ?? "Host error")
                events.append(event)
                if end(event) { return events }
            }
        }
        let successID = "10000000-0000-4000-8000-000000000001"
        for id in [successID, "10000000-0000-4000-8000-000000000002"] {
            try await send(NativeCommand(op: "open", session: id))
            let opened = try await until { $0.op == "synced" }
            let expectedStage = id == successID ? "modelCompleted" : "failed"
            let liveFile = root.appendingPathComponent(id + ".json")
            if phase == "live" {
                try await send(NativeCommand(op: "prompt", session: id, id: UUID().uuidString,
                    text: id == successID ? "Inspect the request budget" : "DIAGNOSTIC_HTTP_FAILURE"))
                let events = try await until { $0.op == "stage" && ["completed", "failed"].contains($0.stage ?? "") }
                let final = events.compactMap(\.request).last!
                precondition(final.stage == expectedStage && final.validIdentity)
                precondition(final.inputTokens == 12_345 && final.capacity == 32_768 && final.reserve == 4096)
                precondition(final.inputKind == "exact" && final.string("budget.capabilities.capacity.source") == "provider")
                precondition(events.contains { $0.stage == "preparing" && $0.request?.id == final.id })
                precondition(events.contains { $0.stage == "measuring" && $0.request?.id == final.id })
                if id == successID {
                    precondition(final.tokens("usage.totalTokens") == 12_585)
                    precondition(final.milliseconds("firstReasoningMS") != nil && final.milliseconds("firstTextMS") != nil)
                    precondition(events.filter { $0.stage == "firstText" }.count == 1)
                } else {
                    precondition(final.string("code") == "HTTP_400" && final.milliseconds("firstTextMS") == nil)
                    precondition(final.tokens("usage.promptTokens") == nil)
                }
                try JSONEncoder().encode(final).write(to: liveFile)
                try await send(NativeCommand(op: "open", session: id))
                let replay = try await until { $0.op == "synced" }
                var folded = NativeTranscript(); replay.forEach { folded.apply($0) }; replay.dropFirst().forEach { folded.apply($0) }
                precondition(folded.requests == [final], "Replay must restore metadata exactly once")
                precondition(folded.protocolNotices.isEmpty)
            } else {
                try JSONEncoder().encode(opened).write(to: root.appendingPathComponent(id + "-events.json"))
                let original = try JSONDecoder().decode(NativeRequestInfo.self, from: Data(contentsOf: liveFile))
                var folded = NativeTranscript(); opened.forEach { folded.apply($0) }
                precondition(folded.requests == [original], "Final metadata must survive a host restart")
                precondition(folded.requests.last?.stage == expectedStage)
            }
        }
        print("PASS host request metadata: " + phase + " success/failure, exact budget, usage and replay")
    }
}
