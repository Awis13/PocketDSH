import Foundation

/// One session transport shared by chat and terminal presentations.
@MainActor
final class NativeChatConnection {
    var onEvent: ((NativeEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var sender: Task<Void, Error>?
    private var generation = UUID()
    var selectedID: String?

    static func parse(_ input: String) throws -> (URL, String?) {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, parts.user == nil, parts.password == nil,
              parts.scheme == "wss" || (parts.scheme == "ws" && ["127.0.0.1", "localhost", "::1"].contains(host)),
              parts.path.isEmpty || parts.path == "/" else {
            throw HarnessError(message: "Use a wss:// Native Harness address, or ws://127.0.0.1:8768 on this Mac.")
        }
        let token = parts.queryItems?.first { $0.name == "token" }?.value
        parts.query = nil; parts.fragment = nil; parts.path = ""
        guard let url = parts.url else { throw HarnessError(message: "Invalid Native Harness address") }
        return (url, token)
    }
    func connect(url: URL, token: String) {
        disconnect()
        let run = generation
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: request)
        ws.maximumMessageSize = 2_097_152
        socket = ws; ws.resume()
        reader = Task { [weak self] in
            do {
                try await self?.send(NativeCommand(op: "list"))
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                    guard let self, self.generation == run else { return }
                    self.onEvent?(try JSONDecoder().decode(NativeEvent.self, from: data))
                }
            } catch {
                guard let self, self.generation == run, !Task.isCancelled else { return }
                self.onFailure?("Native connection interrupted: " + error.localizedDescription)
                self.disconnect()
            }
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.generation == run else { return }
                do {
                    if let id = self.selectedID { try await self.send(NativeCommand(op: "status", session: id)) }
                } catch { /* The reader reports connection loss. */ }
            }
        }
    }
    func send(_ command: NativeCommand) async throws {
        guard let socket else { throw HarnessError(message: "Native Harness is disconnected") }
        let previous = sender, run = generation
        let operation = Task { @MainActor [weak self] in
            if let previous { try await previous.value }
            guard let self, self.generation == run, !Task.isCancelled else { throw CancellationError() }
            try await socket.send(.string(String(decoding: JSONEncoder().encode(command), as: UTF8.self)))
        }
        sender = operation
        try await operation.value
    }
    func disconnect() {
        generation = UUID(); reader?.cancel(); poller?.cancel(); sender?.cancel(); sender = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; selectedID = nil
    }
}

/// Folds native events into the same rows rendered by the existing rich chat.
struct NativeTranscript {
    private(set) var rows: [TranscriptRow] = []
    private var sequence = 0
    private var toolArguments: [String: String] = [:]
    private var toolStreams: [String: [String: Data]] = [:]
    mutating func apply(_ event: NativeEvent) {
        if event.op == "opened" { rows = []; sequence = 0; toolArguments = [:]; toolStreams = [:]; return }
        if let next = event.sequence {
            guard next > sequence else { return }; sequence = next
        }
        func finish() {
            for i in rows.indices where rows[i].kind != .shell { rows[i].complete = true }
        }
        switch event.op {
        case "blockStart":
            let block = NativeBlock(id: event.id ?? String(sequence), command: event.text ?? "", directory: event.workspace ?? "")
            rows.append(TranscriptRow(id: "shell-" + block.id, kind: .shell, text: block.command, complete: false, shell: block))
        case "blockEnd", "ptyExit":
            if let i = rows.lastIndex(where: { $0.kind == .shell && !$0.complete }) {
                rows[i].complete = true; rows[i].failed = (event.exitCode ?? 0) != 0
                rows[i].shell?.finished = true; rows[i].shell?.exitCode = event.exitCode
                rows[i].shell?.interrupted = event.failed == true || event.op == "ptyExit"
            }
        case "user":
            let id = "native-user-" + (event.id ?? String(sequence))
            guard !rows.contains(where: { $0.id == id }) else { return }
            let prompt = ShellPromptContent.parse(event.text ?? "")
            rows.append(TranscriptRow(id: id, kind: .user, text: prompt.question, detail: prompt.readableContext))
        case "text", "reasoning":
            let kind: TranscriptRow.Kind = event.op == "text" ? .assistant : .reasoning
            if let i = rows.lastIndex(where: { $0.kind != .shell }), rows[i].kind == kind, !rows[i].complete { rows[i].text += event.text ?? "" }
            else { rows.append(TranscriptRow(id: "native-\(event.op)-\(sequence)", kind: kind, text: event.text ?? "", complete: false)) }
        case "toolCall":
            finish()
            let id = "tool-" + (event.id ?? String(sequence))
            let arguments = Self.arguments(event.arguments ?? "")
            toolArguments[id] = arguments
            rows.append(TranscriptRow(id: id, kind: .tool, text: event.text ?? "Tool", detail: arguments, complete: false))
        case "shellOutput":
            if let i = rows.lastIndex(where: { $0.kind == .tool && $0.text == "shell" && !$0.complete }), let bytes = event.bytes {
                let id = rows[i].id, stream = event.text ?? "stdout"
                var streams = toolStreams[id] ?? [:]
                var buffer = streams[stream] ?? Data()
                buffer.append(bytes.prefix(max(0, 65536 - buffer.count)))
                streams[stream] = buffer; toolStreams[id] = streams
                rows[i].detail = (toolArguments[id] ?? "") + "\n\n" + ["stdout", "stderr"].compactMap { key in
                    streams[key].map { String(decoding: $0, as: UTF8.self) }
                }.joined(separator: "\n")
            }
        case "toolResult":
            if let i = rows.firstIndex(where: { $0.id == "tool-" + (event.id ?? "") }) {
                rows[i].detail = (toolArguments.removeValue(forKey: rows[i].id) ?? "") + "\n\n" + Self.result(event.text ?? "", tool: rows[i].text)
                toolStreams.removeValue(forKey: rows[i].id)
                rows[i].complete = true; rows[i].failed = event.failed ?? false
            }
        case "stage":
            if ["modelCompleted", "turnCompleted", "completed", "cancelled", "failed", "interrupted"].contains(event.stage ?? "") { finish() }
            if event.stage == "interrupted" { rows.append(TranscriptRow(id: "native-interrupted-\(sequence)", kind: .notice, text: event.text ?? "Response interrupted by host restart", failed: true)) }
            if event.stage == "cancelled" || event.stage == "failed" {
                rows.append(TranscriptRow(id: "native-end-\(sequence)", kind: .notice,
                                          text: event.stage == "cancelled" ? "Response stopped" : event.text == "CONTEXT_LIMIT" ? "Model context limit exceeded. Terminal and conversation are preserved." : "Native Harness turn failed", failed: event.stage == "failed"))
            }
        case "shellReset": rows.append(TranscriptRow(id: "native-shell-reset-\(sequence)", kind: .notice, text: event.text ?? "New shell; previous commands were not rerun."))
        default: break
        }
    }

    private static func arguments(_ text: String) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return text }
        if let command = json["command"] as? String { return "$ " + command }
        return json.keys.sorted().map { "\($0): \(json[$0]!)" }.joined(separator: "\n")
    }
    private static func result(_ text: String, tool: String) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return text }
        if tool == "shell", let stdout = json["stdout"] as? String {
            return [stdout, json["stderr"] as? String ?? "", "exit \(json["exitCode"].map { String(describing: $0) } ?? "unknown") · \(json["outcome"] as? String ?? "")"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if ["terminal_read", "terminal_wait"].contains(tool), let preview = json["text"] as? String {
            // Old journals contain raw terminal bytes as well as text. Display
            // the readable excerpt, never pages of duplicated base64.
            let plain = preview.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]|\x1B[()][0-~]"#, with: "", options: .regularExpression)
            let clipped = plain.utf8.count > 4096 || json["previewTruncated"] as? Bool == true
            return String(plain.suffix(4096)) + (clipped ? "\n[terminal excerpt clipped]" : "") + "\nnext cursor: \(json["nextCursor"].map { String(describing: $0) } ?? "unknown")"
        }
        return text
    }
    mutating func updateShell(_ block: NativeBlock) {
        guard let i = rows.firstIndex(where: { $0.id == "shell-" + block.id }) else { return }
        rows[i].shell = block; rows[i].complete = block.finished
        rows[i].failed = block.interrupted || (block.exitCode ?? 0) != 0
    }

}
