import SwiftUI
import UIKit

private enum NativePaneMode: String, CaseIterable { case chat = "Chat", terminal = "Terminal" }
private struct NativePane: Identifiable {
    let id = UUID()
    let client: NativeClient
    var mode: NativePaneMode
}
private enum WorkspaceAction: String, CaseIterable, Identifiable {
    case splitRight = "Split right", splitDown = "Split down", next = "Next pane", previous = "Previous pane"
    case maximize = "Maximize / restore", close = "Close active pane", chat = "Show chat", terminal = "Show terminal"
    var id: String { rawValue }
    var command: String {
        switch self {
        case .splitRight: "split right"; case .splitDown: "split down"; case .next: "focus next"
        case .previous: "focus previous"; case .maximize: "maximize"; case .close: "close"
        case .chat: "view chat"; case .terminal: "view terminal"
        }
    }
}
@MainActor
private final class NativeWorkspace: ObservableObject {
    @Published var panes: [NativePane] = []
    @Published var layout: AgentLayout?
    @Published var active: UUID?
    @Published var maximized = false
    @Published var palette = false
    @Published var retired: [NativePane] = []
    @Published var frames: [UUID: CGRect] = [:]
    @Published var focusRevision = UUID()
    var endpoint = ""
    var token = ""
    var selected: NativePane? { panes.first { $0.id == active } }
    func start(endpoint: String, token: String) {
        guard panes.isEmpty else { return }
        self.endpoint = endpoint; self.token = token
        let client = NativeClient(endpoint: endpoint, token: token)
        let chat = NativePane(client: client, mode: .chat), terminal = NativePane(client: client, mode: .terminal)
        panes = [chat, terminal]; layout = .split(UUID(), false, .pane(chat.id), .pane(terminal.id)); active = terminal.id
        bind(client); client.connect()
    }
    private func bind(_ client: NativeClient) {
        client.onWorkspaceAction = { [weak self, weak client] name in
            guard let self, let client, let action = WorkspaceAction.allCases.first(where: { $0.command == name }),
                  let pane = self.panes.first(where: { $0.client === client && $0.mode == .terminal }) else { return }
            self.activate(pane.id); self.perform(action)
        }
        client.onAgent = { [weak self, weak client] in
            guard let self, let client else { return }
            client.attachTerminal = true
            if let chat = self.panes.first(where: { $0.client === client && $0.mode == .chat }) { self.activate(chat.id) }
            else if let index = self.panes.firstIndex(where: { $0.id == self.active }) { self.panes[index].mode = .chat; self.focusRevision = UUID() }
        }
    }
    func activate(_ id: UUID) {
        active = id; focusRevision = UUID()
        if let pane = selected, pane.mode == .terminal, pane.client.shellRunning { pane.client.terminal.requestInputFocus() }
    }
    func perform(_ action: WorkspaceAction) {
        guard let current = selected else { return }
        switch action {
        case .splitRight, .splitDown:
            guard panes.count < 8, let layout else { return }
            let client = NativeClient(endpoint: endpoint, token: token)
            let pane = NativePane(client: client, mode: current.mode)
            panes.append(pane); self.layout = layout.splitting(current.id, new: pane.id, stacked: action == .splitDown)
            maximized = false; activate(pane.id); bind(client); client.connect()
        case .close:
            guard panes.count > 1, let next = layout?.removing(current.id) else { return }
            retired.append(current); panes.removeAll { $0.id == current.id }; layout = next; maximized = false; activate(next.first)
        case .next, .previous:
            guard let i = panes.firstIndex(where: { $0.id == active }) else { return }
            activate(panes[(i + (action == .next ? 1 : panes.count - 1)) % panes.count].id)
        case .maximize: maximized.toggle(); focusRevision = UUID()
        case .chat, .terminal:
            guard let i = panes.firstIndex(where: { $0.id == active }) else { return }
            let mode: NativePaneMode = action == .chat ? .chat : .terminal
            // A terminal surface has one visible owner. Focus an existing view instead of reparenting it.
            if mode == .terminal, let other = panes.first(where: { $0.client === current.client && $0.mode == .terminal && $0.id != current.id }) { activate(other.id) }
            else { panes[i].mode = mode; focusRevision = UUID() }
        }
    }
    func direction(dx: CGFloat, dy: CGFloat) {
        guard let id = active, let origin = frames[id] else { return }
        let matches = frames.filter { key, rect in
            key != id && (dx != 0 ? (rect.midX - origin.midX) * dx > 1 : (rect.midY - origin.midY) * dy > 1)
        }
        if let next = matches.min(by: { a, b in
            hypot(a.value.midX - origin.midX, a.value.midY - origin.midY) < hypot(b.value.midX - origin.midX, b.value.midY - origin.midY)
        }) { activate(next.key) }
    }
    func disconnect() { for pane in panes + retired { pane.client.disconnect() } }
    func reopen() {
        guard panes.count < 8, let pane = retired.popLast(), let current = active, let layout else { return }
        panes.append(pane); self.layout = layout.splitting(current, new: pane.id, stacked: false); maximized = false; activate(pane.id)
    }
}

struct NativeWorkspaceView: View {
    @AppStorage("harness.nativeMode") private var enabled = false
    @AppStorage("harness.nativeEndpoint") private var endpoint = "ws://127.0.0.1:8768"
    @State private var token = ""
    @State private var settingsError: String?
    @State private var query = ""
    @StateObject private var workspace = NativeWorkspace()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.purple)
                Text("Native workspace").fontWeight(.semibold)
                Text("\(workspace.panes.count) panes").foregroundStyle(.secondary)
                Spacer()
                if !workspace.retired.isEmpty { Button("Reopen pane") { workspace.reopen() }.keyboardShortcut("t", modifiers: [.command, .shift]) }
                Button { workspace.palette = true } label: { Label("Commands", systemImage: "command") }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button { workspace.perform(.splitRight) } label: { Image(systemName: "rectangle.split.2x1") }.keyboardShortcut("d", modifiers: .command).help("Split right (⌘D)")
                Button { workspace.perform(.splitDown) } label: { Image(systemName: "rectangle.split.1x2") }.keyboardShortcut("d", modifiers: [.command, .shift]).help("Split down (⌘⇧D)")
                Button { workspace.perform(.maximize) } label: { Image(systemName: workspace.maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.keyboardShortcut("\r", modifiers: [.command, .shift]).help("Maximize / restore")
                Button { workspace.perform(.close) } label: { Image(systemName: "xmark") }.disabled(workspace.panes.count < 2).help("Close active pane; session stays running (⌘W)")
                Button("DSH") { enabled = false }.help("Return to DeepSeek Harness client")
            }.font(.callout).padding(14)
            Divider()
            if let layout = workspace.layout {
                render(workspace.maximized ? .pane(workspace.active ?? layout.first) : layout)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Connect to Native Harness").font(.title2.bold())
                    Text("One workspace for chat and your persistent shell.").foregroundStyle(.secondary)
                    TextField("WebSocket endpoint", text: $endpoint).textFieldStyle(.roundedBorder)
                    SecureField("Host token", text: $token).textFieldStyle(.roundedBorder)
                    Button("Open chat + terminal") { connect() }.buttonStyle(.borderedProminent)
                    if let settingsError { Text(settingsError).foregroundStyle(.red) }
                    Text("Start the Mac host with harness --host. The initial host listens on localhost; iPad needs a secure tunnel to that host.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: 500).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(red: 0.10, green: 0.11, blue: 0.14)).foregroundStyle(.white)
            .background { PaneCloseCommandBridge(onClose: { workspace.perform(.close) }).frame(width: 0, height: 0) }
            .background { navigationKeys }
            .coordinateSpace(name: "nativeWorkspace")
            .onPreferenceChange(NativePaneFrames.self) { workspace.frames = $0 }
            .sheet(isPresented: $workspace.palette) { palette }
            .onDisappear { workspace.disconnect() }
            .task {
                guard workspace.panes.isEmpty else { return }
                #if DEBUG
                if let path = ProcessInfo.processInfo.environment["HARNESS_NATIVE_CONFIG"],
                   let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let config = try? JSONDecoder().decode([String: String].self, from: data), let secret = config["token"] {
                    endpoint = config["endpoint"] ?? endpoint; token = secret; workspace.start(endpoint: endpoint, token: token); return
                }
                #endif
                token = SecureConnection.read("native-host-token:" + endpoint) ?? ""
                if !token.isEmpty { workspace.start(endpoint: endpoint, token: token) }
            }
    }
    private func connect() {
        do { try SecureConnection.write(token, key: "native-host-token:" + endpoint); workspace.start(endpoint: endpoint, token: token) }
        catch { settingsError = error.localizedDescription }
    }
    private var navigationKeys: some View {
        HStack {
            Button("Next pane") { workspace.perform(.next) }.keyboardShortcut("]", modifiers: .command)
            Button("Previous pane") { workspace.perform(.previous) }.keyboardShortcut("[", modifiers: .command)
            Button("Left pane") { workspace.direction(dx: -1, dy: 0) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Right pane") { workspace.direction(dx: 1, dy: 0) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Pane above") { workspace.direction(dx: 0, dy: -1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Pane below") { workspace.direction(dx: 0, dy: 1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }.frame(width: 0, height: 0).clipped().accessibilityHidden(true)
    }
    private var palette: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workspace commands").font(.title2.bold())
            TextField("Search: split, focus, view, close…", text: $query).textFieldStyle(.roundedBorder).onSubmit {
                if let action = actions.first { run(action) }
            }
            ForEach(actions) { action in
                Button { run(action) } label: {
                    HStack { Text(action.rawValue); Spacer(); Text(action.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }.padding(.vertical, 5)
                }.buttonStyle(.plain)
            }
            Text("⌘D split right · ⌘⇧D split down · ⌘[ / ⌘] navigate · ⌘W close").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 460)
    }
    private var actions: [WorkspaceAction] { WorkspaceAction.allCases.filter { query.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(query) || $0.command.localizedCaseInsensitiveContains(query) } }
    private func run(_ action: WorkspaceAction) { workspace.palette = false; query = ""; workspace.perform(action) }
    private func render(_ layout: AgentLayout) -> AnyView {
        switch layout {
        case .pane(let id):
            guard let pane = workspace.panes.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
            return AnyView(NativePaneView(client: pane.client, mode: pane.mode, active: workspace.active == id, focusRevision: workspace.focusRevision,
                activate: { if workspace.active != id { workspace.activate(id) } }, change: { workspace.activate(id); workspace.perform($0 == .chat ? .chat : .terminal) },
                command: { workspace.palette = true }, close: { workspace.activate(id); workspace.perform(.close) })
                .background { GeometryReader { geometry in Color.clear.preference(key: NativePaneFrames.self, value: [id: geometry.frame(in: .named("nativeWorkspace"))]) } }
                .overlay { Rectangle().stroke(workspace.active == id ? Color.purple.opacity(0.75) : .clear, lineWidth: 1).allowsHitTesting(false) }.id(id))
        case .split(let id, let stacked, let a, let b): return AnyView(AgentSplitView(stacked: stacked, first: render(a), second: render(b)).id(id))
        }
    }
}
private struct NativePaneFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, b in b }) }
}

private struct NativePaneView: View {
    @ObservedObject var client: NativeClient
    let mode: NativePaneMode
    let active: Bool
    let focusRevision: UUID
    let activate: () -> Void
    let change: (NativePaneMode) -> Void
    let command: () -> Void
    let close: () -> Void
    @State private var focusRequest: UUID?
    @State private var expanded: Set<String> = []
    @State private var history = true
    @State private var follow = true
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(client.connected ? .green : .orange).frame(width: 6, height: 6)
                Menu { ForEach(NativePaneMode.allCases, id: \.self) { value in Button(value.rawValue) { change(value) } } } label: { Label(mode.rawValue, systemImage: mode == .chat ? "bubble.left" : "terminal") }
                Text(client.directory).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if mode == .terminal { Button { history.toggle() } label: { Image(systemName: "list.bullet.rectangle") }.help("Show command blocks") }
                Button(action: command) { Image(systemName: "command") }
                Button(action: close) { Image(systemName: "xmark") }
            }.font(.callout).padding(12).contentShape(Rectangle()).onTapGesture(perform: activate)
            Divider()
            if let error = client.error {
                HStack { Text(error).lineLimit(3); Spacer(); Button("Dismiss") { client.error = nil } }.font(.caption).foregroundStyle(.orange).padding(8)
            }
            if !client.connected { Button("Reconnect") { client.connect() }.padding(8) }
            if mode == .terminal { terminalBody } else { chatBody }
        }.environment(\.agentPaneActivate, activate)
            .simultaneousGesture(TapGesture().onEnded(activate))
            .onChange(of: focusRevision) { _, _ in if active { focusRequest = UUID() } }
            .onAppear { if active { focusRequest = UUID() } }
            .onChange(of: client.shellRunning) { _, running in if active && !running { focusRequest = UUID() } }
    }
    private var terminalBody: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if history && !client.blocks.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(client.blocks) { block in blockRow(block).id(block.id) }
                            }
                        }.onChange(of: client.blocks.count) { _, _ in if let id = client.blocks.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                    }.frame(height: client.shellRunning ? min(geometry.size.height * 0.22, 160) : max(80, geometry.size.height - 130))
                    Divider()
                }
                if client.shellRunning {
                    NativeTerminalView(client: client, focus: active, revision: focusRevision).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if client.blocks.isEmpty { Spacer() }
                    HStack(alignment: .top, spacing: 10) {
                        Text("❯").font(.system(size: 19, weight: .bold, design: .monospaced)).foregroundStyle(.purple).padding(.top, 8)
                        DesktopPromptEditor(text: $client.shellDraft, focusRequest: $focusRequest, collapsed: false, ink: .white, monospaced: true, sendToAgent: { client.sendShellToAgent() }, send: { client.runShell() })
                            .frame(minHeight: 44, maxHeight: 80)
                    }.padding(.horizontal, 14).padding(.top, 8)
                }
                HStack {
                    Text(client.shellExited ? "Shell exited" : client.shellRunning ? "Command running" : "Shell ready")
                    Spacer()
                    Button("Ask agent  ⌘↩") { client.sendShellToAgent() }.keyboardShortcut("\r", modifiers: .command).disabled(!active)
                    Button("Interrupt") { client.send(NativeCommand(op: "interrupt", session: client.id)) }.disabled(client.shellExited)
                }.font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
    }
    private func blockRow(_ block: NativeBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: block.finished ? (block.exitCode == 0 ? "checkmark.circle" : "exclamationmark.circle") : "circle.dotted").foregroundStyle(block.exitCode == nil || block.exitCode == 0 ? Color.purple : .orange)
                Button { if expanded.contains(block.id) { expanded.remove(block.id) } else { expanded.insert(block.id) } } label: { Text(block.command).font(.system(.callout, design: .monospaced)).lineLimit(expanded.contains(block.id) ? nil : 2).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                Menu {
                    Button("Copy command") { UIPasteboard.general.string = block.command }
                    Button("Copy visible output") { UIPasteboard.general.string = block.preview }
                    Button("Ask agent about this block") {
                        client.draft = "Explain this command and its output:\n\nCommand: \(block.command)\nDirectory: \(block.directory)\nExit: \(block.exitCode.map(String.init) ?? "running")\nOutput (bounded preview):\n\(block.preview)"
                        client.attachTerminal = false; change(.chat)
                    }
                } label: { Image(systemName: "ellipsis") }
            }
            if expanded.contains(block.id) || (block.finished && !block.preview.isEmpty) {
                Text(block.preview.isEmpty ? (block.finished ? "No output" : "Output is streaming below") : block.preview).font(.system(.caption, design: .monospaced)).lineLimit(expanded.contains(block.id) ? nil : 2).textSelection(.enabled)
                if block.truncated { Text("Captured output truncated").font(.caption).foregroundStyle(.orange) }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.025))
    }
    private var chatBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if client.chats.isEmpty { Text("What shall we work on?").font(.title2.bold()).padding(.top, 30) }
                        ForEach(client.chats) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.role == "user" ? "YOU" : "AGENT").font(.caption.bold()).foregroundStyle(.purple)
                                AssistantMarkdown(text: message.text).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !client.reasoning.isEmpty { DisclosureGroup("Reasoning") { Text(client.reasoning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
                        Color.clear.frame(height: 1).id("bottom").onAppear { follow = true }.onDisappear { follow = false }
                    }.padding(20)
                }.onChange(of: client.chats.last?.text) { _, _ in if follow { proxy.scrollTo("bottom", anchor: .bottom) } }
                if !follow { Button("Latest output ↓") { follow = true; proxy.scrollTo("bottom", anchor: .bottom) }.font(.caption) }
            }
            ForEach(client.approvals) { approval in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow \(approval.name)?").bold()
                    Text(approval.arguments).font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                    HStack { Button("Allow once") { client.answer(approval, allow: true) }; Button("Reject") { client.answer(approval, allow: false) } }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.1))
            }
            Divider()
            VStack(spacing: 6) {
                HStack { Text(client.model).lineLimit(1); Spacer(); Text(client.running ? "Agent is working…" : "Ready") }.font(.caption).foregroundStyle(.secondary)
                DesktopPromptEditor(text: $client.draft, focusRequest: $focusRequest, collapsed: false, ink: .white, send: {
                    if client.draft.trimmingCharacters(in: .whitespacesAndNewlines) == "/pane" { client.draft = ""; command() }
                    else { client.submit() }
                }).frame(minHeight: 42, maxHeight: 100)
                HStack {
                    Toggle("Attach terminal tail (16 KB)", isOn: $client.attachTerminal).font(.caption)
                    Spacer()
                    if client.running { Button("Stop") { client.send(NativeCommand(op: "cancel", session: client.id)) } }
                    Button("Send ↑") { client.submit() }.disabled(!client.connected || client.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(14)
        }
    }
}
