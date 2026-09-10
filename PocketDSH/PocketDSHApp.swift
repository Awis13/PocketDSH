import SwiftUI

@main
struct PocketDSHApp: App {
    init() {
        #if targetEnvironment(macCatalyst)
        // Use transient overlay scrollers in this app, regardless of mouse type.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        #endif
    }
    @UIApplicationDelegateAdaptor(PocketMacAppDelegate.self) private var macDelegate
    @AppStorage("harness.theme") private var themeName = HarnessTheme.system.rawValue
    private var theme: HarnessTheme { HarnessTheme(rawValue: themeName) ?? .system }
    @StateObject private var store = PocketStore()
    @StateObject private var notifications = TurnNotifications.shared
    @State private var started = false
    @State private var needsResume = false
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder private var content: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DSH_APPROVAL_PREVIEW"] == "1" {
            ApprovalKeyboardPreview()
        } else if let sample = ProcessInfo.processInfo.environment["DSH_MARKDOWN_PREVIEW"] {
            ScrollView { AssistantMarkdown(text: sample).padding(20) }
        } else { HomeView() }
        #else
        HomeView()
        #endif
    }
    var body: some Scene {
        WindowGroup {
            content.modifier(HarnessGlassGroup()).environmentObject(store)
                .environment(\.locale, Locale(identifier: "en"))
                .fontDesign(theme.design).environment(\.harnessTheme, theme).preferredColorScheme(theme.scheme).tint(theme.accent)
                .task {
                    guard !started else { return }; started = true
                    #if DEBUG
                    // Device setup via USB: import a second server without switching the current pane.
                    let connectionSeed = URL.documentsDirectory.appending(path: "debug-native-connection")
                    if let input = try? String(contentsOf: connectionSeed, encoding: .utf8) {
                        try? FileManager.default.removeItem(at: connectionSeed)
                        do {
                            let (url, token) = try NativeChatConnection.parse(input)
                            guard let token, token.utf8.count >= 32 else { throw HarnessError(message: "Native connection seed is missing its host token.") }
                            try SecureConnection.write(token, key: "native:" + url.absoluteString)
                            SavedConnections.remember(url.absoluteString)
                        } catch { store.error = error.localizedDescription }
                    }
                    let seed = URL.documentsDirectory.appending(path: "debug-login-url")
                    let login = ProcessInfo.processInfo.environment["DSH_LOGIN_URL"] ?? (try? String(contentsOf: seed, encoding: .utf8))
                    if FileManager.default.fileExists(atPath: seed.path) { try? FileManager.default.removeItem(at: seed) }
                    await store.connect(input: login)
                    #else
                    await store.connect()
                    #endif
                }
                .task(id: notifications.destination) {
                    guard let target = notifications.destination else { return }
                    guard target["endpoint"] == store.endpoint else { notifications.destination = nil; return }
                    if !store.connected { await store.connect() }
                    if let id = target["session"], store.sessions.contains(where: { $0.id == id }) { await store.select(id) }
                    notifications.destination = nil
                }
                .onChange(of: scenePhase) { _, phase in
                    guard !store.workspaceDetached else { return }
                    #if targetEnvironment(macCatalyst)
                    if phase == .active && !store.connected && !store.connecting { Task { await store.connect() } }
                    #else
                    if phase == .background { needsResume = true; store.suspend() }
                    if needsResume && phase == .active { needsResume = false; Task { await store.connect() } }
                    #endif
                }
        }
    }
}

import UIKit

@MainActor
private enum PaneCommands {
    struct Handlers {
        var close: () -> Void
        var focus: (PaneFocusDirection) -> Void
        var maximize: () -> Void
    }
    static var handlers: [ObjectIdentifier: Handlers] = [:]
    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
    }
    private static func current() -> Handlers? {
        guard let window = keyWindow() else { return nil }
        return handlers[ObjectIdentifier(window)]
    }
    static func closeActivePane() { current()?.close() }
    static func moveFocus(_ direction: PaneFocusDirection) { current()?.focus(direction) }
    static func toggleMaximize() { current()?.maximize() }
}
final class PocketMacAppDelegate: UIResponder, UIApplicationDelegate {
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        // Remove the system Close Window command instead of competing with it.
        builder.remove(menu: .close)
        let close = UIKeyCommand(title: "Close Active Pane", action: #selector(closePane), input: "w", modifierFlags: .command)
        close.wantsPriorityOverSystemBehavior = true
        builder.insertChild(UIMenu(title: "", identifier: UIMenu.Identifier("dev.awis.close-pane"), options: .displayInline, children: [close]), atStartOfMenu: .file)
        // Directional pane focus and maximize must be claimed before the
        // focused terminal turns the same chords into PTY bytes.
        let focus = [
            UIKeyCommand(title: "Focus Pane Left", action: #selector(focusPane(_:)), input: UIKeyCommand.inputLeftArrow, modifierFlags: [.control, .alternate]),
            UIKeyCommand(title: "Focus Pane Right", action: #selector(focusPane(_:)), input: UIKeyCommand.inputRightArrow, modifierFlags: [.control, .alternate]),
            UIKeyCommand(title: "Focus Pane Above", action: #selector(focusPane(_:)), input: UIKeyCommand.inputUpArrow, modifierFlags: [.control, .alternate]),
            UIKeyCommand(title: "Focus Pane Below", action: #selector(focusPane(_:)), input: UIKeyCommand.inputDownArrow, modifierFlags: [.control, .alternate])
        ]
        let maximize = UIKeyCommand(title: "Maximize or Restore Pane", action: #selector(toggleMaximizePane), input: "m", modifierFlags: [.command, .shift])
        (focus + [maximize]).forEach { $0.wantsPriorityOverSystemBehavior = true }
        builder.insertChild(UIMenu(title: "", identifier: UIMenu.Identifier("dev.awis.pane-focus"), options: .displayInline, children: focus + [maximize]), atStartOfMenu: .view)
    }
    @objc private func closePane(_ sender: UIKeyCommand) { PaneCommands.closeActivePane() }
    @objc private func focusPane(_ sender: UIKeyCommand) {
        let direction: PaneFocusDirection
        switch sender.input {
        case UIKeyCommand.inputLeftArrow: direction = .left
        case UIKeyCommand.inputRightArrow: direction = .right
        case UIKeyCommand.inputUpArrow: direction = .up
        default: direction = .down
        }
        PaneCommands.moveFocus(direction)
    }
    @objc private func toggleMaximizePane(_ sender: UIKeyCommand) { PaneCommands.toggleMaximize() }
}
/// Registers the key-window handlers for pane commands (close, directional
/// focus and maximize). The Mac menu dispatches to them; iPad uses the hidden
/// SwiftUI shortcuts in `NativeShellPane`.
struct PaneCommandBridge: UIViewRepresentable {
    let onClose: () -> Void
    var onFocus: ((PaneFocusDirection) -> Void)? = nil
    var onMaximize: (() -> Void)? = nil
    func makeUIView(context: Context) -> PaneCommandView { PaneCommandView() }
    func updateUIView(_ view: PaneCommandView, context: Context) {
        view.onClose = onClose; view.onFocus = onFocus; view.onMaximize = onMaximize; view.registerWindow()
    }
    static func dismantleUIView(_ view: PaneCommandView, coordinator: ()) { view.unregisterWindow() }
}
final class PaneCommandView: UIView {
    var onClose: (() -> Void)?
    var onFocus: ((PaneFocusDirection) -> Void)?
    var onMaximize: (() -> Void)?
    private var registeredWindow: ObjectIdentifier?
    override func didMoveToWindow() { super.didMoveToWindow(); registerWindow() }
    func unregisterWindow() {
        if let registeredWindow { PaneCommands.handlers.removeValue(forKey: registeredWindow) }
        registeredWindow = nil
    }
    func registerWindow() {
        unregisterWindow()
        guard let window, let onClose else { return }
        let key = ObjectIdentifier(window)
        registeredWindow = key
        PaneCommands.handlers[key] = PaneCommands.Handlers(close: onClose, focus: onFocus ?? { _ in }, maximize: onMaximize ?? {})
    }
}
