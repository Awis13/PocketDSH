import SwiftUI
import UIKit

struct HarnessMark: View {
    @Environment(\.harnessTheme) private var theme
    var body: some View {
        Image(systemName: "terminal").font(.system(size: 21, weight: .semibold))
            .frame(width: 42, height: 42).background(Color.primary, in: RoundedRectangle(cornerRadius: 13))
            .foregroundStyle(theme.canvas)
    }
}
struct HomeView: View {
    @Environment(\.harnessTheme) private var theme
    @EnvironmentObject var store: PocketStore
    @State private var connection = false
    @State private var appearance = false
    @State private var newTask = false
    @State private var search = ""
    @State private var workspace: String?
    @State private var activeOnly = false
    var filtered: [HarnessSession] {
        store.visibleSessions.filter { s in
            (search.isEmpty || s.title.localizedCaseInsensitiveContains(search)) &&
            (!activeOnly || s.running || store.interactions.contains { $0.sessionID == s.id }) &&
            (workspace == nil || store.workspaces.first { $0.id == workspace }?.sessionIDs.contains(s.id) == true)
        }
    }
    var body: some View {
        #if targetEnvironment(macCatalyst)
        DesktopHomeView()
        #else
        if UIDevice.current.userInterfaceIdiom == .pad { DesktopHomeView() }
        else { mobileBody }
        #endif
    }
    private var mobileBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HarnessMark()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Harness").font(.system(size: 26, weight: .semibold, design: theme.digital ? .monospaced : .rounded))
                        Button { connection = true } label: {
                            HStack(spacing: 5) {
                                Circle().fill(store.connected ? .green : .orange).frame(width: 5, height: 5)
                                Text(store.connected ? "Mac · connected" : store.connecting ? "Connecting…" : "Connect your Mac")
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            }.font(.caption).foregroundStyle(.secondary)
                        }.accessibilityIdentifier("connection")
                    }
                    Spacer()
                    Button { appearance = true } label: { Image(systemName: "paintpalette").font(.title3).frame(width: 36, height: 44) }.accessibilityLabel("Appearance")
                    Button { newTask = true } label: { Image(systemName: "square.and.pencil").font(.title3).frame(width: 44, height: 44) }
                        .accessibilityLabel("New task").disabled(!store.connected)
                }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 24)
                ThemeSignature()
                HStack {
                    Text(theme == .hacker ? "> Your tasks" : "Your tasks").font(.system(size: 32, weight: .bold, design: theme.design))
                    Spacer()
                    Text("\(store.visibleSessions.count)").font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
                }.padding(.horizontal, 22)
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search tasks", text: $search).accessibilityIdentifier("sessionSearch")
                }.padding(12).harnessSurface(radius: 14, control: true).padding(.horizontal, 22).padding(.top, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", selected: !activeOnly && workspace == nil) { activeOnly = false; workspace = nil }
                        chip("Running", selected: activeOnly) { activeOnly.toggle() }
                        ForEach(store.workspaces) { w in chip(w.title, selected: workspace == w.id) { workspace = workspace == w.id ? nil : w.id } }
                    }.padding(.horizontal, 22)
                }.padding(.vertical, 16)
                if let error = store.error { errorBanner(error) }
                if store.sessions.isEmpty {
                    Spacer()
                    Image(systemName: store.connected ? "text.bubble" : "laptopcomputer").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                    Text(store.connected ? "Where shall we start?" : "Your agent, wherever you are").font(.title2.weight(.semibold)).padding(.top, 12)
                    Text(store.connected ? "Create a task. It will appear on your Mac too." : "Connect to Harness on your Mac to continue from your phone.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 40).padding(.top, 4)
                    Button(store.connected ? "New task" : "Connect Harness") { if store.connected { newTask = true } else { connection = true } }
                        .buttonStyle(.borderedProminent).tint(.primary).padding(.top, 18)
                    Spacer(); Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { session in
                                Button { Task { await store.select(session.id) } } label: { sessionRow(session) }
                                    .buttonStyle(.plain).accessibilityIdentifier("session-\(session.id)")
                            }
                            if filtered.isEmpty { ContentUnavailableView.search(text: search) }
                        }.padding(.horizontal, 22).padding(.bottom, 24)
                    }.refreshable { await store.refresh() }
                }
            }.background { ThemeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: Binding(get: { store.selectedID != nil }, set: { if !$0 { Task { await store.select(nil) } } })) { HarnessView() }
                .sheet(isPresented: $appearance) { AppearanceView() }
                .sheet(isPresented: $connection) { ConnectionView() }
                .sheet(isPresented: $newTask, onDismiss: { store.focusNewSessionComposer() }) { NewTaskView() }
        }.tint(theme.accent).foregroundStyle(theme.ink)
    }
    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 9)
            .background(selected ? (theme.digital ? theme.accent : Color.primary) : theme.surface, in: RoundedRectangle(cornerRadius: theme.digital ? 3 : 30)).foregroundStyle(selected ? theme.canvas : theme.ink) }
    }
    private func sessionRow(_ session: HarnessSession) -> some View {
        let waiting = store.interactions.contains { $0.sessionID == session.id }
        return HStack(alignment: .top, spacing: 13) {
            Image(systemName: waiting ? "hand.raised" : session.running ? "circle.dotted" : "bubble.left")
                .font(.system(size: 18, weight: .regular)).foregroundStyle(waiting ? .orange : session.running ? theme.accent : .secondary)
                .frame(width: 24).padding(.top, 3)
            VStack(alignment: .leading, spacing: 7) {
                Text(session.title).font(.system(size: 16, weight: .medium, design: theme.design)).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(waiting ? "Needs your input" : session.running ? "Running" : URL(fileURLWithPath: session.cwd).lastPathComponent)
                        .foregroundStyle(waiting || session.running ? theme.accent : .secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(sessionAge(session.date)).foregroundStyle(.tertiary)
                }.font(.caption).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.top, 6)
        }.padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5).padding(.leading, 37) }
    }
    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "wifi.exclamationmark")
            Text(text).font(.caption)
            Spacer()
            Button("Sign in") { connection = true }.font(.caption.bold())
        }.foregroundStyle(.orange).padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 22).padding(.bottom, 10)
    }
}
struct NewTaskView: View {
    @Environment(\.harnessTheme) private var theme
    @EnvironmentObject var store: PocketStore
    @Environment(\.dismiss) var dismiss
    @State private var workspace: String?
    @State private var creating = false
    var body: some View {
        NavigationStack {
            List {
                Section("Where the agent will work") {
                    choice(store.usesNativeHarness ? "Native host working directory" : "DSH working directory", id: nil)
                    ForEach(store.workspaces) { w in choice(w.title, id: w.id) }
                }
                Section { Text(store.usesNativeHarness ? "Files and execution stay on the Native Harness host." : "Files and execution stay on your Mac. The task will also be available in your browser.").font(.footnote).foregroundStyle(.secondary) }
            }.scrollContentBackground(.hidden).background { ThemeBackdrop() }.navigationTitle("New task").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(creating ? "Creating…" : "Create") { creating = true; Task { await store.create(workspaceID: workspace); creating = false; if store.selectedID != nil { dismiss() } } }.disabled(creating || !store.connected)
                    }
                }
        }
    }
    func choice(_ title: String, id: String?) -> some View {
        Button { workspace = id } label: { HStack { Label(title, systemImage: "folder"); Spacer(); if workspace == id { Image(systemName: "checkmark") } } }.foregroundStyle(.primary)
    }
}

struct DesktopPaneView: View {
    @EnvironmentObject private var store: PocketStore
    @Environment(\.harnessTheme) private var theme
    @AppStorage private var sidebar: Bool
    init(sidebarKey: String, initiallyVisible: Bool) {
        _sidebar = AppStorage(wrappedValue: initiallyVisible, sidebarKey)
    }
    @State private var search = ""
    @State private var activeOnly = false
    @State private var workspace: String?
    @State private var connection = false
    @State private var appearance = false
    @State private var newTask = false
    private var sessions: [HarnessSession] {
        store.visibleSessions.filter { session in
            (search.isEmpty || session.title.localizedCaseInsensitiveContains(search) || session.cwd.localizedCaseInsensitiveContains(search)) &&
            (!activeOnly || session.running || store.interactions.contains { $0.sessionID == session.id }) &&
            (workspace == nil || store.workspaces.first { $0.id == workspace }?.sessionIDs.contains(session.id) == true)
        }
    }
    private var host: String { URL(string: store.endpoint)?.host ?? store.endpoint }
    var body: some View {
        GeometryReader { geometry in
        let overlaySidebar = UIDevice.current.userInterfaceIdiom == .pad && geometry.size.width < 700
        HStack(spacing: 0) {
            if sidebar && !overlaySidebar {
                sidebarContent(overlay: false).frame(width: 280)
                    .background(theme.usesGlass ? Color.clear : theme.surface.opacity(0.6))
                    .modifier(HarnessNavigationSurface()).padding(theme.usesGlass ? 8 : 0)
                Divider()
            }
            VStack(spacing: 0) {
                header
                if !theme.usesGlass { Divider() }
                if let error = store.error {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Connection") { connection = true }
                    }.padding(12).background(Color.orange.opacity(0.08))
                }
                if store.selectedID != nil {
                    if store.nativeShellMode, let shell = store.nativeShell {
                        NativeShellPane(client: shell)
                            .id(shell.id)
                    } else { HarnessView() }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "terminal").font(.system(size: 40, weight: .light)).foregroundStyle(theme.accent)
                        Text("What shall we work on?").font(.largeTitle.weight(.semibold))
                        Text("Choose a conversation or start a new task.").foregroundStyle(.secondary)
                        Button("New task", systemImage: "square.and.pencil") { newTask = true }
                            .buttonStyle(.borderedProminent).disabled(!store.connected)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.environment(\.nativePanelTerminal, $store.nativeShellMode)
        .background { ThemeBackdrop() }.foregroundStyle(theme.ink).tint(theme.accent)
        .onChange(of: store.composerFocusRequest) { _, request in
            if request != nil && overlaySidebar { sidebar = false }
        }
        .overlay(alignment: .leading) {
            if sidebar && overlaySidebar {
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.25).onTapGesture { sidebar = false }
                    sidebarContent(overlay: true).frame(width: min(280, geometry.size.width - 44))
                        .padding(.vertical, 8).background(theme.canvas)
                }
            }
        }
        }
            .sheet(isPresented: $connection) { ConnectionView() }
            .sheet(isPresented: $appearance) { AppearanceView() }
            .sheet(isPresented: $newTask, onDismiss: { store.focusNewSessionComposer() }) { NewTaskView() }
            .task(id: store.connected) {
                guard store.connected, store.openDefaultTaskWhenConnected else { return }
                store.openDefaultTaskWhenConnected = false
                await store.createDefaultTask()
            }
    }
    private func sidebarContent(overlay: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Harness", systemImage: "terminal").font(.title3.weight(.semibold))
                Spacer()
                Button { newTask = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New task").accessibilityIdentifier("desktopNewTask")
                    .disabled(!store.connected)
            }.padding(.top, 20)
            TextField("Search tasks", text: $search).textFieldStyle(.roundedBorder).accessibilityIdentifier("sessionSearch")
            HStack {
                Menu {
                    Button("All workspaces") { workspace = nil }
                    ForEach(store.workspaces) { item in Button(item.title) { workspace = item.id } }
                } label: { Label(store.workspaces.first { $0.id == workspace }?.title ?? "All workspaces", systemImage: "folder").lineLimit(1) }
                Spacer(minLength: 4)
                Toggle(isOn: $activeOnly) { Image(systemName: "bolt") }.toggleStyle(.button)
                    .help("Only running tasks and tasks needing your input")
            }.font(.caption)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(sessions) { session in
                        Button { Task { await store.select(session.id) }; if overlay { sidebar = false } } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(session.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                                HStack(spacing: 5) {
                                    let waiting = store.interactions.contains { $0.sessionID == session.id }
                                    Circle().fill(waiting ? Color.orange : session.running ? theme.accent : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                                    Text(waiting ? "Needs input" : session.running ? "Running" : URL(fileURLWithPath: session.cwd).lastPathComponent).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(sessionAge(session.date)).lineLimit(1)
                                }.font(.caption2).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(store.selectedID == session.id ? theme.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("session-" + session.id)
                    }
                    if sessions.isEmpty { Text(search.isEmpty ? "No tasks here" : "No matching tasks").font(.caption).foregroundStyle(.secondary).padding() }
                }
            }
            Divider()
            HStack {
                Text("\(sessions.count) tasks").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { appearance = true } label: { Image(systemName: "paintpalette") }.accessibilityLabel("Appearance")
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh tasks")
            }.padding(.bottom, 14)
        }.padding(.horizontal, 14)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Button { sidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel(sidebar ? "Hide sidebar" : "Show sidebar").accessibilityIdentifier("toggleSidebar")

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.selected?.title ?? "Pocket DSH").font(.headline).lineLimit(1)
                    if !store.readingMode, let session = store.selected {
                        Text(session.cwd).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(session.cwd)
                    }
                }
                Spacer(minLength: 12)
                if store.usesNativeHarness, store.selectedID != nil {
                    Picker("Panel mode", selection: $store.nativeShellMode) {
                        Text("Chat").tag(false)
                        Text("Shell").tag(true)
                    }.pickerStyle(.segmented).frame(width: 150).disabled(store.nativeShell == nil)
                }
                Button { connection = true } label: {
                    HStack(spacing: 6) {
                        Circle().fill(store.connected ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(host).lineLimit(1)
                    }.font(.caption)
                }.accessibilityIdentifier("connection").help(store.endpoint)
                Menu {
                    Button("New task", systemImage: "square.and.pencil") { newTask = true }
                    Button("Appearance", systemImage: "paintpalette") { appearance = true }
                    Button("Reconnect", systemImage: "arrow.clockwise") { Task { await store.connect() } }
                    Button("Connection", systemImage: "network") { connection = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Conversation options")
            }
            if store.selectedID != nil && !store.readingMode {
                HStack(spacing: 16) {
                    Label(store.modelLabel, systemImage: "cpu").lineLimit(1)
                    if store.usesNativeHarness { Text("Native Harness").foregroundStyle(theme.accent) }
                    Label(!store.connected ? "Offline" : !store.currentInteractions.isEmpty ? "Needs your input" : store.running ? "Working" : "Ready", systemImage: store.running ? "circle.dotted" : "circle")
                    if !store.currentQueue.isEmpty { Text("\(store.currentQueue.count) queued") }
                    Spacer(minLength: 0)
                    Text(store.nativeShellMode ? "Enter runs · ⌘Enter asks agent" : "Enter to send · Shift+Enter for newline").lineLimit(1)
                }.font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("desktopTaskInfo")
            }
        }.padding(.horizontal, 20).padding(.vertical, store.readingMode ? 7 : 14)
            .modifier(HarnessNavigationSurface()).padding(theme.usesGlass ? 8 : 0)
    }
}

private struct NativePanelTerminalKey: EnvironmentKey { static let defaultValue: Binding<Bool>? = nil }
extension EnvironmentValues {
    var nativePanelTerminal: Binding<Bool>? {
        get { self[NativePanelTerminalKey.self] }
        set { self[NativePanelTerminalKey.self] = newValue }
    }
}

private struct AgentPaneActiveKey: EnvironmentKey { static let defaultValue = true }
private struct AgentPaneActivateKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var agentPaneIsActive: Bool {
        get { self[AgentPaneActiveKey.self] }
        set { self[AgentPaneActiveKey.self] = newValue }
    }
    var agentPaneActivate: () -> Void {
        get { self[AgentPaneActivateKey.self] }
        set { self[AgentPaneActivateKey.self] = newValue }
    }
}
indirect enum AgentLayout: Codable {
    case pane(UUID)
    case split(UUID, Bool, AgentLayout, AgentLayout)
    func splitting(_ target: UUID, new: UUID, stacked: Bool) -> AgentLayout {
        switch self {
        case .pane(let id): return id == target ? .split(UUID(), stacked, self, .pane(new)) : self
        case .split(let id, let axis, let a, let b): return .split(id, axis, a.splitting(target, new: new, stacked: stacked), b.splitting(target, new: new, stacked: stacked))
        }
    }
    func removing(_ target: UUID) -> AgentLayout? {
        switch self {
        case .pane(let id): return id == target ? nil : self
        case .split(let id, let axis, let a, let b):
            let left = a.removing(target), right = b.removing(target)
            if let left, let right { return .split(id, axis, left, right) }
            return left ?? right
        }
    }
    var first: UUID {
        switch self { case .pane(let id): return id; case .split(_, _, let a, _): return a.first }
    }
    var panes: [UUID] {
        switch self { case .pane(let id): return [id]; case .split(_, _, let a, let b): return a.panes + b.panes }
    }
}
@MainActor
private final class AgentWorkspace: ObservableObject {
    @Published var layout: AgentLayout?
    @Published var active: UUID? { didSet { save() } }
    @Published var fractions: [UUID: Double] = [:] { didSet { save() } }
    @Published var sizes: [UUID: CGSize] = [:]
    func canSplit(stacked: Bool) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return true }
        guard let active, let size = sizes[active] else { return false }
        return stacked ? size.height >= 566 : size.width >= 646
    }
    var stores: [UUID: PocketStore] = [:]
    var initial: UUID?
    private struct SavedWorkspace: Codable {
        var layout: AgentLayout
        var active: UUID
        var initial: UUID
        var panes: [UUID: PocketStore.SavedPane]
        var fractions: [UUID: Double]
    }
    private var ready = false
    private let storageKey = "harness.agentWorkspace.v1"
    private func save() {
        guard ready, let layout, let active, let initial else { return }
        let snapshot = SavedWorkspace(layout: layout, active: active, initial: initial, panes: stores.mapValues(\.savedPane), fractions: fractions)
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: storageKey) }
        if let pane = stores[initial], let data = try? JSONEncoder().encode(pane.savedPane) { UserDefaults.standard.set(data, forKey: "harness.primaryPane.v1") }
    }
    private func observe(_ store: PocketStore) { store.onWorkspaceChange = { [weak self] in self?.save() } }
    func prepare(_ store: PocketStore) {
        guard layout == nil else { return }
        if let data = UserDefaults.standard.data(forKey: storageKey), let saved = try? JSONDecoder().decode(SavedWorkspace.self, from: data),
           !saved.panes.isEmpty, saved.panes.count <= 8, Set(saved.layout.panes) == Set(saved.panes.keys),
           saved.layout.panes.count == saved.panes.count, saved.panes[saved.initial] != nil, saved.panes[saved.active] != nil,
           saved.panes[saved.initial]?.endpoint == store.endpoint {
            initial = saved.initial; active = saved.active; fractions = saved.fractions
            for (id, state) in saved.panes {
                let pane = id == initial ? store : PocketStore(restoringPrimary: false)
                // The app owns the primary connection and may already be opening it.
                if id != initial { pane.restorePane(state) }
                stores[id] = pane; observe(pane)
                if id != initial { Task { await pane.connect() } }
            }
            layout = saved.layout; ready = true
            return
        }
        let id = UUID(); stores[id] = store; initial = id; active = id; layout = .pane(id)
        observe(store); ready = true; save()
    }
    func split(stacked: Bool) {
        guard canSplit(stacked: stacked), let active, let source = stores[active], let layout else { return }
        let id = UUID(), store = PocketStore(restoringPrimary: false)
        store.endpoint = source.endpoint
        observe(store)
        store.openDefaultTaskWhenConnected = true
        stores[id] = store
        self.layout = layout.splitting(active, new: id, stacked: stacked)
        self.active = id
        let endpoint = source.endpoint
        Task {
            await store.connect(input: endpoint)
            guard self.stores[id] != nil else { store.suspend(); return }
        }
    }
    func close() {
        guard stores.count > 1, let active, let next = layout?.removing(active) else { return }
        stores.removeValue(forKey: active)?.detachPane()
        if active == initial { initial = next.first }
        layout = next; self.active = next.first
    }
}
struct DesktopHomeView: View {
    @EnvironmentObject private var store: PocketStore
    @Environment(\.harnessTheme) private var theme
    @Environment(\.scenePhase) private var phase
    @StateObject private var workspace = AgentWorkspace()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(workspace.stores.count == 1 ? "1 agent pane" : "\(workspace.stores.count) agent panes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { workspace.split(stacked: false) } label: { Label("Split side by side", systemImage: "rectangle.split.2x1").frame(minWidth: 32, minHeight: 32) }
                    .keyboardShortcut("d", modifiers: .command).accessibilityIdentifier("splitVertical").disabled(!workspace.canSplit(stacked: false))
                Button { workspace.split(stacked: true) } label: { Label("Split top and bottom", systemImage: "rectangle.split.1x2").frame(minWidth: 32, minHeight: 32) }
                    .keyboardShortcut("d", modifiers: [.command, .shift]).accessibilityIdentifier("splitHorizontal").disabled(!workspace.canSplit(stacked: true))
                Button { workspace.close() } label: { Image(systemName: "xmark") }
                    .opacity(workspace.stores.count > 1 ? 1 : 0.35)
                    .help(workspace.stores.count > 1 ? "Close active pane (⌘W); the agent continues on the server" : "The last pane stays open")
                    .accessibilityLabel("Close active pane")
                    #if !targetEnvironment(macCatalyst)
                    .keyboardShortcut("w", modifiers: .command)
                    #endif
            }.font(.caption)
                #if targetEnvironment(macCatalyst)
                .labelStyle(.titleAndIcon)
                #else
                .labelStyle(.iconOnly)
                #endif
                .padding(.horizontal, 16).frame(minHeight: 44).padding(.vertical, 4)
            if let layout = workspace.layout { render(layout) }
        }.background { ThemeBackdrop() }
            .background { PaneCloseCommandBridge(onClose: { workspace.close() }).frame(width: 0, height: 0) }
            .onPreferenceChange(AgentPaneSizes.self) { if workspace.sizes != $0 { workspace.sizes = $0 } }
            .onAppear { workspace.prepare(store) }
            .onChange(of: phase) { _, phase in
                for (id, pane) in workspace.stores where id != workspace.initial {
                    #if !targetEnvironment(macCatalyst)
                    if phase == .background { pane.suspend() }
                    #endif
                    if phase == .active && !pane.connected && !pane.connecting { Task { await pane.connect() } }
                }
            }
    }
    private func render(_ layout: AgentLayout) -> AnyView {
        switch layout {
        case .pane(let id):
            guard let pane = workspace.stores[id] else { return AnyView(EmptyView()) }
            return AnyView(DesktopPaneView(sidebarKey: id == workspace.initial ? "harness.mac.sidebar" : "harness.mac.sidebar." + id.uuidString, initiallyVisible: id == workspace.initial).environmentObject(pane)
                .environment(\.agentPaneActivate, { workspace.active = id })
                .environment(\.agentPaneIsActive, workspace.active == id)
                .overlay { Rectangle().stroke(workspace.active == id && workspace.stores.count > 1 ? theme.accent.opacity(0.7) : .clear, lineWidth: 1).allowsHitTesting(false) }
                .background { GeometryReader { geometry in Color.clear.preference(key: AgentPaneSizes.self, value: [id: geometry.size]) } }
                .simultaneousGesture(TapGesture().onEnded { workspace.active = id })
                .id(id))
        case .split(let id, let stacked, let a, let b):
            return AnyView(AgentSplitView(stacked: stacked, first: render(a), second: render(b), savedFraction: workspace.fractions[id], onResize: { workspace.fractions[id] = $0 }).id(id))
        }
    }
}
private struct AgentPaneSizes: PreferenceKey {
    static var defaultValue: [UUID: CGSize] = [:]
    static func reduce(value: inout [UUID: CGSize], nextValue: () -> [UUID: CGSize]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
struct AgentSplitView: View {
    let stacked: Bool
    let first: AnyView
    let second: AnyView
    var savedFraction: Double? = nil
    var onResize: ((Double) -> Void)? = nil
    @State private var fraction: CGFloat = 0.5
    var body: some View {
        GeometryReader { geometry in
            let length = max(1, (stacked ? geometry.size.height : geometry.size.width) - 6)
            if stacked {
                VStack(spacing: 0) {
                    first.frame(height: length * fraction)
                    divider(length: length)
                    second.frame(height: length * (1 - fraction))
                }
            } else {
                HStack(spacing: 0) {
                    first.frame(width: length * fraction)
                    divider(length: length)
                    second.frame(width: length * (1 - fraction))
                }
            }
        }.coordinateSpace(name: "split-divider")
            .onAppear { if let savedFraction, savedFraction.isFinite { fraction = min(0.8, max(0.2, savedFraction)) } }
    }
    private func divider(length: CGFloat) -> some View {
        Rectangle().fill(Color.secondary.opacity(0.2))
            .frame(width: stacked ? nil : 6, height: stacked ? 6 : nil)
            .contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .named("split-divider")).onChanged { value in
                fraction = min(0.8, max(0.2, (stacked ? value.location.y : value.location.x) / length))
            }.onEnded { _ in onResize?(Double(fraction)) })
            .accessibilityLabel("Resize agent panes")
    }
}

// Keep session timestamps static between data updates: SwiftUI relative-date
// Text schedules continuous layout updates for every visible sidebar row.
private func sessionAge(_ date: Date) -> String {
    let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
    if minutes < 1 { return "Now" }
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 1440 { return "\(minutes / 60)h" }
    return "\(minutes / 1440)d"
}
