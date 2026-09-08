import Foundation

/// One-time capture from the pre-journal host before upgrading it. No execution.
@main struct NativeArchive {
    struct Snapshot: Codable { var info: NativeSessionInfo; var events: [NativeEvent] }
    static func main() async throws {
        let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var request = URLRequest(url: URL(string: config["endpoint"]!)!)
        request.setValue("Bearer " + config["token"]!, forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request); socket.resume()
        let timeout = Task { try? await Task.sleep(for: .seconds(45)); socket.cancel(with: .goingAway, reason: nil) }
        defer { timeout.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        func send(_ command: NativeCommand) async throws { try await socket.send(.string(String(decoding: JSONEncoder().encode(command), as: UTF8.self))) }
        func next() async throws -> NativeEvent {
            let message = try await socket.receive()
            let data: Data
            switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: fatalError() }
            let event = try JSONDecoder().decode(NativeEvent.self, from: data)
            if event.op == "error" { throw NSError(domain: "archive", code: 1, userInfo: [NSLocalizedDescriptionKey: event.text ?? "Host error"]) }
            return event
        }
        try await send(NativeCommand(op: "list"))
        let list = try await next()
        guard let sessions = list.sessions, sessions.allSatisfy({ !$0.running }) else { throw NSError(domain: "archive", code: 2, userInfo: [NSLocalizedDescriptionKey: "A session is running; leave the host alive."]) }
        var snapshots: [Snapshot] = []
        for info in sessions {
            try await send(NativeCommand(op: "open", session: info.id))
            var events: [NativeEvent] = []
            while true {
                let event = try await next()
                if event.op == "synced" { break }
                if event.op != "opened" { events.append(event) }
                if event.gap == true { throw NSError(domain: "archive", code: 3, userInfo: [NSLocalizedDescriptionKey: "Host already dropped old output; capture requires explicit gap handling."]) }
            }
            snapshots.append(Snapshot(info: info, events: events))
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try JSONEncoder().encode(snapshots).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("Captured \(snapshots.count) sessions, \(snapshots.reduce(0) { $0 + $1.events.count }) ordered events.")
    }
}
