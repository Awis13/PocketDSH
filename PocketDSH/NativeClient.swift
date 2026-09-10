import Foundation
import SwiftUI
import SwiftTerm
import UIKit

@MainActor
final class NativeClient: ObservableObject {
    let id: String
    @Published var connected = false
    @Published var status = "Connecting…"
    @Published var error: String?
    @Published var model = ""
    @Published var directory = ""
    @Published var chats: [NativeChat] = []
    @Published var blocks: [NativeBlock] = []
    @Published var approvals: [NativeApproval] = []
    @Published var running = false
    @Published var shellRunning = false
    @Published var shellExited = false
    @Published var reasoning = ""
    @Published var draft = ""
    @Published var shellDraft = ""
    @Published private(set) var commandHistory: [String] = []
    @Published private(set) var suggestionHistory: [ShellHistoryEntry] = []
    @Published private(set) var completionReply: NativeEvent?
    func requestCompletion(_ input: ShellCompletionInput, id: String) {
        guard connected, !syncing, !shellRunning, !shellExited else { return }
        send(NativeCommand(op: "complete", session: self.id, id: id, text: input.token, completionKind: input.kind))
    }
    @Published var attachTerminal = false
    /// How the single live terminal surface is presented. Driven by the
    /// alternate buffer so a full-screen TUI can own the active pane.
    @Published private(set) var presentation = TerminalPresentation()
    let terminal = NativeTerminalSurface(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
    private let endpoint: String
    private let token: String
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var activeBlock: String?
    private var assistantID: String?
    private var sequence = 0
    private var pendingSends = 0
    private var syncing = true
    private var generation = UUID()
    private var delegate: NativeTerminalDelegate!
    init(id: String = UUID().uuidString, endpoint: String, token: String) {
        self.id = id; self.endpoint = endpoint; self.token = token
        delegate = NativeTerminalDelegate(client: self)
        terminal.terminalDelegate = delegate
        terminal.nativeBackgroundColor = UIColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1)
        terminal.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        TerminalAppearance(theme: .dracula, scheme: .dark).apply(to: terminal)
        terminal.accessibilityIdentifier = "nativeTerminal"
        terminal.onAgent = { [weak self] in self?.onAgent?() }
    }
    var onAgent: (() -> Void)?
    var onWorkspaceAction: ((String) -> Void)?
    func connect() {
        disconnect()
        guard let url = URL(string: endpoint), url.scheme == "ws" || url.scheme == "wss", !token.isEmpty else {
            error = "Enter a WebSocket URL and host token"; return
        }
        let run = UUID(); generation = run
        var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: request); socket = ws; ws.resume()
        status = "Connecting…"; error = nil
        send(NativeCommand(op: "open", session: id))
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    let data: Data
                    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                    guard let self, self.generation == run else { return }
                    self.receive(try JSONDecoder().decode(NativeEvent.self, from: data))
                }
            } catch {
                guard let self, self.generation == run, !Task.isCancelled else { return }
                self.connected = false; self.status = "Disconnected"; self.error = error.localizedDescription
            }
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.generation == run else { return }
                if self.connected { self.send(NativeCommand(op: "status", session: self.id)) }
            }
        }
    }
    func disconnect() {
        generation = UUID(); reader?.cancel(); poller?.cancel(); sender?.cancel(); sender = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; connected = false; pendingSends = 0
    }
    var externalSend: ((NativeCommand) -> Void)?
    func send(_ command: NativeCommand) {
        if let externalSend { externalSend(command); return }
        guard let socket, pendingSends < 256 else { error = "Connection unavailable or input queue full"; return }
        let previous = sender, run = generation
        pendingSends += 1
        sender = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.generation == run else { return }
            defer { self.pendingSends -= 1 }
            do {
                let data = try JSONEncoder().encode(command)
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            } catch { self.error = error.localizedDescription }
        }
    }
    func input(_ bytes: Data) { guard connected, !shellExited else { return }; send(NativeCommand(op: "input", session: id, bytes: bytes)) }
    func interruptCommand() { guard connected, !shellExited else { return }; send(NativeCommand(op: "interrupt", session: id)) }
    func resize(columns: Int, rows: Int) {
        guard connected, !syncing, !shellExited else { return }
        send(NativeCommand(op: "resize", session: id, rows: max(1, min(1000, rows)), columns: max(1, min(1000, columns))))
    }
    func prepareForCommand(width: CGFloat, height: CGFloat) {
        guard !shellRunning else { return }
        let width = max(180, width)
        let height = max(120, height)
        terminal.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let cellWidth = ceil(("W" as NSString).size(withAttributes: [.font: terminal.font]).width)
        let cellHeight = ceil(terminal.font.lineHeight)
        let columns = max(20, Int(width / max(1, cellWidth)))
        let rows = max(2, Int(height / max(1, cellHeight)))
        terminal.getTerminal().resize(cols: columns, rows: rows)
        resize(columns: columns, rows: rows)
    }
    /// The alternate buffer changed ownership. A full-screen TUI expands the
    /// surface to the active pane; releasing it collapses back to the feed.
    func terminalBufferActivated(alternate: Bool) {
        if alternate {
            presentation.alternateBufferActivated(anchor: activeBlock ?? blocks.last?.id)
        } else {
            presentation.alternateBufferDeactivated()
        }
    }
    func returnToTranscript() { presentation.returnToTranscript() }
    func consumeReturnAnchor() -> String? { presentation.consumeAnchor() }
    func runShell() {
        guard connected, !shellExited, !shellRunning, !shellDraft.isEmpty else { return }
        let text = shellDraft
        guard text.utf8.count < 60000 else { error = "Shell input is too large"; return }
        shellDraft = ""; shellRunning = true
        input(Data(("\u{1b}[200~" + text + "\u{1b}[201~\r").utf8))
    }
    func sendShellToAgent() {
        if !shellDraft.isEmpty { draft = shellDraft; shellDraft = "" }
        onAgent?()
        if !draft.isEmpty { submit() }
    }
    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, connected else { return }
        send(NativeCommand(op: "prompt", session: id, id: UUID().uuidString, text: text, withTerminal: attachTerminal))
        draft = ""; attachTerminal = false
    }
    func answer(_ approval: NativeApproval, allow: Bool) {
        send(NativeCommand(op: "approval", session: id, id: approval.id, allow: allow))
    }
    private func renderedOutput() -> String {
        let text = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
            .replacingOccurrences(of: "\0", with: " ")
            .components(separatedBy: "\n").map { line in
                var value = line
                while value.last == " " { value.removeLast() }
                return value
            }.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return String(text.suffix(65536))
    }
    // Read styled cells from SwiftTerm after it has interpreted ANSI/cursor controls.
    // Do not parse escape sequences again or flatten colored command output.
    private func styledOutput(matching preview: String) -> [NativeStyledRun] {
        let model = terminal.getTerminal()
        var result: [NativeStyledRun] = []
        let count = min(2048, preview.split(separator: "\n", omittingEmptySubsequences: false).count)
        for row in 0..<count {
            guard let line = model.getScrollInvariantLine(row: row) else { return [] }
            var cells: [(Character, Attribute)] = []
            for col in 0..<line.count {
                let cell = line[col], character = cell.getCharacter()
                if cell.width == 0 && character != "\0" { continue }
                cells.append((character == "\0" ? " " : character, cell.attribute))
            }
            while cells.last?.0 == " " { cells.removeLast() }
            for (character, attribute) in cells {
                var run = NativeStyledRun(text: String(character), foreground: rgb(attribute.fg), background: rgb(attribute.bg),
                    foregroundIndex: paletteIndex(attribute.fg), backgroundIndex: paletteIndex(attribute.bg),
                    bold: attribute.style.contains(.bold), underline: attribute.style.contains(.underline),
                    dim: attribute.style.contains(.dim), italic: attribute.style.contains(.italic),
                    crossedOut: attribute.style.contains(.crossedOut), inverse: attribute.style.contains(.inverse))
                if attribute.style.contains(.invisible) { run.text = " " }
                if let last = result.last, last.hasSameStyle(as: run) { result[result.count - 1].text += run.text }
                else { result.append(run) }
            }
            if row < count - 1 { result.append(NativeStyledRun(text: "\n")) }
        }
        // Older lines may have left the emulator's scrollback. Keep the full plain
        // retained preview in that case instead of presenting a partial styled copy.
        return result.map(\.text).joined() == preview ? result : []
    }
    private func paletteIndex(_ color: Attribute.Color) -> Int? {
        if case .ansi256(let code) = color, code < 16 { return Int(code) }
        return nil
    }
    private func rgb(_ color: Attribute.Color) -> Int? {
        switch color {
        case .defaultColor, .defaultInvertedColor: return nil
        case .trueColor(let r, let g, let b): return Int(r) << 16 | Int(g) << 8 | Int(b)
        case .ansi256(let value):
            let code = Int(value)
            if code < 16 { return nil }
            if code >= 232 { let gray = 8 + (code - 232) * 10; return gray << 16 | gray << 8 | gray }
            let n = code - 16, levels = [0, 95, 135, 175, 215, 255]
            return levels[n / 36] << 16 | levels[(n / 6) % 6] << 8 | levels[n % 6]
        }
    }
    func receive(_ event: NativeEvent) {
        if event.op == "opened" {
            connected = true; syncing = true; status = "Restoring…"; sequence = 0
            chats = []; blocks = []; approvals = []; reasoning = ""; activeBlock = nil; assistantID = nil; shellExited = false
            commandHistory = []; completionReply = nil
            suggestionHistory = []
            terminal.getTerminal().resetToInitialState()
            model = event.model ?? ""; directory = event.workspace ?? ""
            if event.gap == true { error = "Only the retained history is available; earlier output was discarded by the host." }
            return
        }
        if event.op == "synced" {
            syncing = false; status = "Ready"
            resize(columns: terminal.getTerminal().cols, rows: terminal.getTerminal().rows); return
        }
        if let seq = event.sequence {
            guard seq > sequence else { return }; sequence = seq
        }
        switch event.op {
        case "completion": completionReply = event
        case "terminalSize":
            if syncing, let columns = event.columns, let rows = event.rows, (1...1000).contains(columns), (1...1000).contains(rows) {
                terminal.getTerminal().resize(cols: columns, rows: rows)
            }
        case "workspaceAction": if !syncing, let action = event.text { onWorkspaceAction?(action) }
        case "pty":
            if let bytes = event.bytes {
                terminal.feed(byteArray: Array(bytes)[...])
                if let id = activeBlock, let i = blocks.firstIndex(where: { $0.id == id }) {
                    let remaining = max(0, 262144 - blocks[i].output.count)
                    blocks[i].output.append(bytes.prefix(remaining))
                    if bytes.count > remaining { blocks[i].truncated = true }
                }
            }
        case "blockStart":
            if let command = event.text, !command.isEmpty {
                let entry = ShellHistoryEntry(command: command, directory: event.workspace ?? directory)
                if suggestionHistory.last != entry { suggestionHistory.append(entry) }
                if suggestionHistory.count > 500 { suggestionHistory.removeFirst(suggestionHistory.count - 500) }
            }
            if let command = event.text, !command.isEmpty, commandHistory.last != command {
                commandHistory.append(command)
                if commandHistory.count > 500 { commandHistory.removeFirst(commandHistory.count - 500) }
            }
            if let old = activeBlock, let i = blocks.firstIndex(where: { $0.id == old }) { blocks[i].finished = true }
            let id = event.id ?? UUID().uuidString
            blocks.append(NativeBlock(id: id, command: event.text ?? "", directory: event.workspace ?? directory))
            if blocks.count > 64 { blocks.removeFirst(blocks.count - 64) }
            activeBlock = id; shellRunning = true
            terminal.getTerminal().resetToInitialState()
        case "blockEnd":
            if let id = activeBlock, let i = blocks.firstIndex(where: { $0.id == id }) {
                blocks[i].exitCode = event.exitCode; blocks[i].finished = true
                blocks[i].interrupted = event.failed == true
                blocks[i].preview = renderedOutput()
                blocks[i].styledOutput = styledOutput(matching: blocks[i].preview)
            }
            activeBlock = nil; shellRunning = false; directory = event.workspace ?? directory
            terminal.getTerminal().resetToInitialState()
        case "ptyExit":
            if let id = activeBlock, let i = blocks.firstIndex(where: { $0.id == id }) {
                blocks[i].finished = true; blocks[i].interrupted = true
                blocks[i].preview = renderedOutput(); blocks[i].styledOutput = styledOutput(matching: blocks[i].preview)
            }
            activeBlock = nil; shellExited = true; shellRunning = false; status = event.text ?? "Shell exited"
        case "shellReset":
            activeBlock = nil; shellExited = false; shellRunning = false; directory = event.workspace ?? directory
            terminal.getTerminal().resetToInitialState()
        case "user": chats.append(NativeChat(id: event.id ?? UUID().uuidString, role: "user", text: event.text ?? "")); assistantID = nil; reasoning = ""; running = true
        case "text":
            if let id = assistantID, let i = chats.firstIndex(where: { $0.id == id }) { chats[i].text += event.text ?? "" }
            else { let id = UUID().uuidString; assistantID = id; chats.append(NativeChat(id: id, role: "assistant", text: event.text ?? "")) }
        case "reasoning": reasoning += event.text ?? ""
        case "stage":
            status = event.stage ?? "Working"
            if ["turnCompleted", "failed", "cancelled"].contains(event.stage ?? "") { assistantID = nil }
        case "status":
            running = event.running ?? false
            if !running { approvals = [] }
            if let issue = event.text, issue != "CANCELLED", issue != error { error = issue }
        case "approval": if let value = event.approval { approvals.removeAll { $0.id == value.id }; approvals.append(value) }
        case "approvalAnswered": approvals.removeAll { $0.id == event.id }
        case "error": error = event.text
        default: break
        }
    }
}

@MainActor
final class NativeTerminalDelegate: TerminalViewDelegate {
    weak var client: NativeClient?
    init(client: NativeClient) { self.client = client }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { client?.input(Data(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { client?.resize(columns: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme ?? "") else { return }
        UIApplication.shared.open(url)
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
