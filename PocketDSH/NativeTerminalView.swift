import SwiftUI
import UIKit
import SwiftTerm

enum ShellTerminalShortcut { case previous, next, find, copyCommand, copyOutput, copyBoth, attach }

final class NativeTerminalSurface: TerminalView {
    var appearance: TerminalAppearance?
    /// Reports alternate-buffer ownership changes (DECSET/DECRST 47/1047/1049).
    var onBufferActivated: ((Bool) -> Void)?
    // SwiftUI measures representables with zero-sized proposals. Such a proposal
    // must not resize the persistent emulator/remote PTY and corrupt its output.
    override var frame: CGRect {
        get { super.frame }
        set { if newValue.width >= 100 && newValue.height >= 40 { super.frame = newValue } }
    }
    override var bounds: CGRect {
        get { super.bounds }
        set { if newValue.width >= 100 && newValue.height >= 40 { super.bounds = newValue } }
    }
    var onAgent: (() -> Void)?
    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onBufferActivated?(source.isCurrentBufferAlternate)
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let host = superview as? NativeTerminalHostView
        let remaining = Set(presses.filter { press in
            guard let key = press.key, let action = host?.action(for: key) else { return true }
            action(); return false
        })
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }
    var pendingFocus = false
    func requestInputFocus() {
        pendingFocus = true
        if window != nil { pendingFocus = !becomeFirstResponder() }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if pendingFocus { requestInputFocus() } }

}

final class NativeTerminalHostView: UIView {
    var askAgent: (() -> Void)?
    var interruptCommand: (() -> Void)?
    var blockShortcut: ((ShellTerminalShortcut) -> Void)?
    private static let blockKeys: [(ShellTerminalShortcut, String, UIKeyModifierFlags, UIKeyboardHIDUsage)] = [
        (.previous, UIKeyCommand.inputUpArrow, [.command, .alternate], .keyboardUpArrow),
        (.next, UIKeyCommand.inputDownArrow, [.command, .alternate], .keyboardDownArrow),
        (.find, "f", .command, .keyboardF), (.copyCommand, "c", [.command, .alternate], .keyboardC),
        (.copyOutput, "c", [.command, .shift], .keyboardC), (.copyBoth, "c", [.command, .alternate, .shift], .keyboardC),
        (.attach, "a", [.command, .shift], .keyboardA)
    ]
    func action(for key: UIKey) -> (() -> Void)? {
        let modifiers = key.modifierFlags.intersection([.command, .alternate, .shift, .control])
        if key.keyCode == .keyboardReturn, modifiers == .command { return askAgent }
        if key.keyCode == .keyboardC, modifiers == .control { return interruptCommand }
        if let blockShortcut, let action = Self.blockKeys.first(where: { $0.3 == key.keyCode && $0.2 == modifiers })?.0 {
            return { blockShortcut(action) }
        }
        return nil
    }
    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        if askAgent != nil { commands.append(UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(askInPlace))) }
        if interruptCommand != nil {
            for key in ["c", "с"] { commands.append(UIKeyCommand(input: key, modifierFlags: .control, action: #selector(interruptInPlace))) }
        }
        if blockShortcut != nil {
            // Command+Option+Up/Down block navigation is owned by the hidden
            // SwiftUI shortcuts in `NativeShellPane`. Registering the same chord
            // here as a key command gives the press two owners, so only the
            // copy/find/attach chords are claimed. `action(for:)` still consumes
            // every block key in `pressesBegan` before SwiftTerm turns it into
            // PTY bytes.
            commands += Self.blockKeys
                .filter { $0.0 != .previous && $0.0 != .next }
                .map { UIKeyCommand(input: $0.1, modifierFlags: $0.2, action: #selector(blockKey(_:))) }
        }
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands + (super.keyCommands ?? [])
    }
    @objc private func askInPlace() { askAgent?() }
    @objc private func interruptInPlace() { interruptCommand?() }
    @objc private func blockKey(_ key: UIKeyCommand) {
        if let action = Self.blockKeys.first(where: { $0.1 == key.input && $0.2 == key.modifierFlags })?.0 { blockShortcut?(action) }
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(askInPlace) { return askAgent != nil }
        if action == #selector(interruptInPlace) { return interruptCommand != nil }
        if action == #selector(blockKey(_:)) { return blockShortcut != nil }
        return super.canPerformAction(action, withSender: sender)
    }
}

struct NativeTerminalView: UIViewRepresentable {
    @Environment(\.harnessTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var client: NativeClient
    let focus: Bool
    let revision: UUID
    var askAgent: (() -> Void)? = nil
    var blockShortcut: ((ShellTerminalShortcut) -> Void)? = nil
    func makeUIView(context: Context) -> NativeTerminalHostView {
        let host = NativeTerminalHostView(frame: client.terminal.frame)
        host.clipsToBounds = true
        client.terminal.removeFromSuperview()
        client.terminal.frame = host.bounds
        client.terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        client.terminal.onBufferActivated = { [weak client] alternate in client?.terminalBufferActivated(alternate: alternate) }
        host.addSubview(client.terminal)
        return host
    }
    func updateUIView(_ host: NativeTerminalHostView, context: Context) {
        host.askAgent = askAgent
        host.interruptCommand = { client.interruptCommand() }
        host.blockShortcut = blockShortcut
        let view = client.terminal
        TerminalAppearance(theme: theme, scheme: scheme).apply(to: view)
        if focus && context.coordinator.revision != revision {
            view.requestInputFocus()
            // Finish the editor's Return action and SwiftUI mounting before
            // taking input ownership. A synchronous success can be overwritten
            // by UITextView completing that same key event.
            DispatchQueue.main.async { view.requestInputFocus() }
        }
        if !focus { view.pendingFocus = false }
        context.coordinator.revision = focus ? revision : nil
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ host: NativeTerminalHostView, coordinator: Coordinator) {
        host.askAgent = nil; host.interruptCommand = nil; host.blockShortcut = nil
        for case let terminal as NativeTerminalSurface in host.subviews {
            terminal.pendingFocus = false
            _ = terminal.resignFirstResponder()
            terminal.onBufferActivated = nil
        }
    }
    final class Coordinator { var revision: UUID? }
}

/// A second presentation of PocketStore.rows, never a second conversation.
struct NativeShellPane: View {
    @Environment(\.colorScheme) private var scheme
    private var appearance: TerminalAppearance { TerminalAppearance(theme: theme, scheme: scheme) }
    @Environment(\.nativePanelTerminal) private var nativePanelTerminal
    @EnvironmentObject private var store: PocketStore
    @Environment(\.harnessTheme) private var theme
    @Environment(\.agentPaneIsActive) private var active
    @Environment(\.agentPaneFocus) private var focusPane
    @Environment(\.agentPaneMaximize) private var maximizePane
    @ObservedObject var client: NativeClient
    @State private var focus: UUID?
    @State private var following = true
    @State private var viewportWidth: CGFloat = 800
    @State private var viewportHeight: CGFloat = 700
    @State private var scrollRequest = 0
    @State private var navigationRevision = 0
    @State private var anchorRequest: String?
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var findFocusRequest = UUID()
    @State private var matchIndex = 0
    @State private var copied: String?
    @State private var history = ShellCommandHistory()
    @State private var completionInput: ShellCompletionInput?
    @State private var completionRequest: String?
    @State private var completions: [String] = []
    @State private var completionIndex = 0
    @State private var completionStatus: String?
    @State private var shellEdit: ShellEditorEdit?
    @AppStorage("harness.shellHistorySuggestions") private var historySuggestions = true
    @FocusState private var findFocused: Bool
    private var blocks: [NativeBlock] { store.rows.compactMap(\.shell) }
    private var selectedBlock: NativeBlock? { blocks.first { $0.id == store.shellSelectedBlockID } }
    private var search: ShellBlockSearch { ShellBlockSearch(output: selectedBlock?.preview ?? "", query: findQuery) }
    private var activeMatch: ShellSearchMatch? { search.match(at: matchIndex) }
    private var canUseActions: Bool { active && store.currentInteractions.isEmpty }
    private var canSuggestHistory: Bool {
        historySuggestions && canUseActions && client.connected && !client.shellRunning && !client.shellExited &&
        !findVisible && completionInput == nil && store.shellAttachments.isEmpty
    }
    private var isExpanded: Bool { client.presentation.isExpanded }
    private var inlineTerminalHeight: CGFloat { max(300, min(560, viewportHeight * 0.6)) }
    /// Expanded terminals are pinned below the full-screen banner and keep the
    /// command header and transcript padding above them. Reserve that chrome
    /// (banner, content padding, block header plus stack spacing) so the bottom
    /// of the emulator and its prompt are not clipped while scrolling is off.
    private var expandedChromeHeight: CGFloat { 48 + 24 + 56 }
    private var terminalHeight: CGFloat { isExpanded ? max(200, viewportHeight - expandedChromeHeight) : inlineTerminalHeight }

    var body: some View {
        VStack(spacing: 0) {
            if !isExpanded {
                ContextStatusView()
                QueueDockView().padding(.horizontal, 20).padding(.top, 8)
                if !blocks.isEmpty { blockToolbar }
                if findVisible { findBar }
            }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(store.rows) { row in
                            Group {
                                if let block = row.shell {
                                    NativeCommandCell(block: block, terminal: true,
                                        selected: block.id == store.shellSelectedBlockID,
                                        select: { select(block.id) }, attach: { attach(block) },
                                        find: { select(block.id); openFind() },
                                        blockShortcut: handleTerminalShortcut,
                                        search: findVisible && block.id == store.shellSelectedBlockID ? search : nil,
                                        activeMatch: activeMatch, searchRevision: navigationRevision)
                                        .id("shell-block-" + block.id)
                                } else {
                                    TranscriptCell(row: row, sessionID: store.selectedID ?? "", terminal: true)
                                }
                            }.environment(\.nativeTerminalHeight, terminalHeight)
                        }
                        if store.rows.isEmpty {
                            Text("Enter runs a command · ⌘Enter asks the agent here")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                        if let pending = store.pendingText {
                            Text("❯ YOU · sending\n" + pending).font(.system(size: theme.messageSize, design: .monospaced))
                        }
                        if store.running && !store.compactingContext {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Agent is working") }
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("shellBottom")
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background { GeometryReader { geometry in Color.clear.preference(key: ConversationContentHeight.self, value: geometry.size.height) } }
                }.scrollIndicators(.hidden).accessibilityIdentifier("shellTranscript")
                    .scrollDisabled(isExpanded)
                    .modifier(ReadingScrollObserver(onScroll: { following = false }, onBottom: {
                        if store.shellSelectedBlockID == nil && !findVisible && !isExpanded { following = true; scrollRequest += 1 }
                    }))
                    .onPreferenceChange(ConversationContentHeight.self) { _ in if following && !isExpanded { scrollRequest += 1 } }
                    .onChange(of: store.rows) { _, _ in if following && !isExpanded { scrollRequest += 1 } }
                    .onAppear { scrollRequest += 1 }
                    .task(id: scrollRequest) {
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                        guard !Task.isCancelled, following, !isExpanded else { return }
                        scroll.scrollTo("shellBottom", anchor: .bottom)
                    }
                    .task(id: navigationRevision) {
                        guard let selected = store.shellSelectedBlockID else { return }
                        do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                        guard !findVisible || activeMatch == nil else { return }
                        scroll.scrollTo("shell-block-" + selected, anchor: .top)
                    }
                    .task(id: anchorRequest) {
                        guard let anchorRequest else { return }
                        do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                        scroll.scrollTo("shell-block-" + anchorRequest, anchor: .top)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !following && !isExpanded { Button { resumeFollowing() } label: { Image(systemName: "arrow.down").frame(width: 44, height: 44) }.accessibilityLabel("Jump to latest output").padding(12) }
                    }
            }.clipped()
            if !isExpanded {
                if let interaction = store.currentInteractions.first {
                    InteractionView(item: interaction).id(interaction.id).frame(maxWidth: 560).padding(16)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ShellAttachmentStrip()
                    completionMenu
                    HStack {
                        Text(client.directory).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if store.running { Button("Stop agent") { Task { await store.cancel() } } }
                        if client.shellRunning {
                            Button("Focus terminal") { closeFind(); focus = nil; client.terminal.requestInputFocus() }
                            Button("Interrupt · Ctrl+C") { client.interruptCommand() }.accessibilityIdentifier("interruptShell")
                            Button("Watch with agent") { ask("Inspect the running command using terminal_inspect, terminal_read and terminal_wait. Follow its progress and report the result without running additional commands.") }
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        Text("❯").foregroundStyle(theme.accent).padding(.top, 8)
                        DesktopPromptEditor(text: $store.draft, focusRequest: $focus, collapsed: false,
                            ink: theme.ink, monospaced: true, textSize: theme.messageSize,
                            suggestionsVisible: !completions.isEmpty,
                            moveSuggestion: moveCompletion, completeSuggestion: acceptCompletion, dismissSuggestions: dismissCompletion,
                            accessibilityName: "Shell command or agent question", accessibilityID: "shellComposer",
                            sendToAgent: store.currentInteractions.isEmpty ? { ask(store.draft) } : nil,
                            interruptCommand: client.shellRunning ? { client.interruptCommand() } : nil,
                            yieldFocusOnSend: !NativeCompactionInfo.isEditorCommand(store.draft, terminalRunning: client.shellRunning), allowsRequestedFocus: !findVisible && (!client.shellRunning || !store.shellAttachments.isEmpty),
                            shellCompletion: client.shellRunning ? nil : requestCompletion,
                            shellHistory: client.shellRunning ? nil : { direction, text, selection in
                                dismissCompletion()
                                return history.move(direction, text: text, selection: selection, history: client.commandHistory)
                            },
                            shellSelectionChanged: { text, selection in
                                if let input = completionInput, input.original != text || input.selection != selection { dismissCompletion() }
                            }, shellEdit: shellEdit,
                            shellSuggestion: canSuggestHistory ? { text in
                                ShellHistorySuggestion.suffix(for: text, directory: client.directory, history: client.suggestionHistory)
                            } : nil, send: run)
                    }.disabled(!client.connected)
                    HStack {
                        Text(client.shellExited ? "Shell exited · agent is available" : client.shellRunning ? "Enter sends input · ⌘Enter asks agent" : "Enter runs · Shift+Enter newline · ⌘Enter asks agent")
                        Spacer()
                        Button("Ask agent") { ask(store.draft) }.disabled(store.draft.isEmpty && store.shellAttachments.isEmpty)
                        Button(client.shellRunning ? "Send input" : "Run") { run() }.disabled(store.draft.isEmpty || client.shellExited)
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
        }.overlay(alignment: .top) { if isExpanded { fullScreenTerminalBanner } }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportWidth = $0.width; viewportHeight = $0.height }
        .background { if canUseActions && !isExpanded { keyboardActions } }
        // Pane focus and maximize must stay reachable when an interaction card
        // hides the block actions or the full-screen terminal is expanded, so
        // they are gated on the active pane alone and registered separately.
        .background { if active { paneActions } }
        .onChange(of: findQuery) { _, _ in matchIndex = 0; navigationRevision += 1 }
        .onChange(of: client.completionReply?.id) { _, _ in receiveCompletion() }
        .onChange(of: store.draft) { _, text in
            if let input = completionInput, input.original != text { dismissCompletion() }
        }
        .onChange(of: store.selectedID) { _, _ in history.reset(); dismissCompletion() }
        .onChange(of: client.presentation) { old, new in
            if new.isExpanded {
                focus = nil
                // A full-screen TUI owns the viewport. Stop bottom-following so
                // new rows (for example a ⌘Enter question) cannot push the
                // expanded terminal out of view, and pin its block to the top.
                following = false
                if let anchor = new.anchor { anchorRequest = anchor }
                client.terminal.requestInputFocus()
            } else if old.isExpanded {
                if let anchor = client.consumeReturnAnchor() { anchorRequest = anchor }
                focusInput()
            }
        }
        .onDisappear { dismissCompletion() }
        .task(id: completionRequest) {
            guard let id = completionRequest else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if completionRequest == id { dismissCompletion(); completionStatus = "Completion unavailable · check the native host connection" }
        }
        .onChange(of: store.selectedID) { _, _ in findVisible = false; findQuery = ""; matchIndex = 0; following = true; scrollRequest += 1 }
        .onChange(of: search.matches.count) { _, count in if matchIndex >= count { matchIndex = 0 } }
        .onAppear {
            appearance.apply(to: client.terminal)
            focusInput()
        }.onChange(of: appearance) { _, value in value.apply(to: client.terminal) }
        .onChange(of: active) { _, _ in dismissCompletion(); focusInput() }
            .onChange(of: client.shellRunning) { _, _ in dismissCompletion(); history.reset(); focusInput() }
    }
    private var fullScreenTerminalBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.inset.filled")
            Text("Full-screen terminal")
            Spacer()
            Button("Return to transcript") { client.returnToTranscript() }
                .accessibilityIdentifier("returnToTranscript")
        }
        .font(.caption).padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
    @ViewBuilder private var completionMenu: some View {
        if !completions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Completions · \(completions.count)\(client.completionReply?.limited == true ? "+" : "")")
                    Spacer()
                    Text("↑↓ select · Tab / Enter insert · Esc close")
                }.font(.caption.monospaced()).foregroundStyle(.secondary)
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(completions.enumerated()), id: \.offset) { index, value in
                                Button { completionIndex = index; acceptCompletion() } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: value.hasSuffix("/") ? "folder" : completionInput?.kind == "command" ? "terminal" : "doc")
                                            .foregroundStyle(theme.accent)
                                        Text(value).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        if index == completionIndex { Image(systemName: "return").foregroundStyle(.secondary) }
                                    }.font(.system(size: 14, design: .monospaced)).padding(.horizontal, 10).frame(minHeight: 40)
                                        .contentShape(Rectangle()).background(index == completionIndex ? theme.accent.opacity(0.15) : .clear)
                                }.buttonStyle(.plain).id(index).accessibilityIdentifier("shellCompletion-\(index)")
                            }
                        }
                    }.frame(height: CGFloat(min(5, completions.count)) * 40).scrollIndicators(.hidden)
                        .onChange(of: completionIndex) { _, index in scroll.scrollTo(index) }
                }
            }.padding(8).background(theme.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        } else if let completionStatus {
            Text(completionStatus).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
    private func requestCompletion(_ text: String, _ selection: NSRange) {
        dismissCompletion()
        if !client.shellRunning, "/compact".hasPrefix(text), text.hasPrefix("/"), selection.length == 0, selection.location == text.utf16.count {
            shellEdit = ShellEditorEdit(original: text, selection: selection, text: "/compact", cursor: 8); store.draft = "/compact"; return
        }
        guard let input = ShellCompletionInput(text, selection: selection) else {
            completionStatus = "Move the caret to a command or path to complete"; return
        }
        let id = UUID().uuidString
        completionInput = input; completionRequest = id; completionStatus = "Completing…"
        client.requestCompletion(input, id: id)
    }
    private func receiveCompletion() {
        guard let reply = client.completionReply, reply.id == completionRequest,
              let input = completionInput, input.original == store.draft else { return }
        completionRequest = nil
        completions = reply.candidates ?? []; completionIndex = 0
        completionStatus = reply.text ?? (completions.isEmpty ? "No matches" : nil)
        if completions.count == 1 && reply.limited != true { acceptCompletion() }
    }
    private func moveCompletion(_ direction: Int) {
        guard !completions.isEmpty else { return }
        completionIndex = (completionIndex + direction + completions.count) % completions.count
    }
    private func acceptCompletion() {
        guard let input = completionInput, input.original == store.draft, completions.indices.contains(completionIndex) else { return }
        let edit = input.replacing(with: completions[completionIndex])
        dismissCompletion(); history.reset(); shellEdit = edit; store.draft = edit.text
    }
    private func dismissCompletion() {
        completionInput = nil; completionRequest = nil; completions = []; completionIndex = 0; completionStatus = nil
    }
    private func focusInput() {
        guard active, !findVisible, store.currentInteractions.isEmpty else { return }
        if client.shellRunning { focus = nil; client.terminal.requestInputFocus() }
        else { focus = UUID() }
    }
    private func run() {
        dismissCompletion(); history.reset()
        let text = store.draft
        if NativeCompactionInfo.isEditorCommand(text, terminalRunning: client.shellRunning) {
            Task { await store.compactContext(fromEditor: true) }; return
        }
        if !client.shellRunning, text.trimmingCharacters(in: .whitespacesAndNewlines) == "/view" {
            store.draft = ""; nativePanelTerminal?.wrappedValue = false; store.composerFocusRequest = UUID(); return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !client.shellExited else { return }
        if client.shellRunning { client.input(Data((text + "\r").utf8)); store.draft = "" }
        else { client.prepareForCommand(width: viewportWidth - 48, height: inlineTerminalHeight); client.shellDraft = text; client.runShell(); if client.shellDraft.isEmpty { store.draft = "" } }
        resumeFollowing()
    }
    private func ask(_ text: String) {
        if NativeCompactionInfo.isEditorCommand(text, terminalRunning: client.shellRunning) {
            Task { await store.compactContext(fromEditor: true) }; return
        }
        dismissCompletion(); history.reset()
        var context: NativeBlock?
        if store.shellAttachments.isEmpty, let selected = client.terminal.getSelection(), !selected.isEmpty {
            context = NativeBlock(id: UUID().uuidString, command: "Selected terminal text", directory: client.directory, preview: selected)
        }
        Task { await store.askFromShell(text, block: context) }
        resumeFollowing(); focus = UUID()
    }

    private func select(_ id: String) {
        store.shellSelectedBlockID = id; following = false; matchIndex = 0; copied = nil; navigationRevision += 1
    }
    private func moveBlock(_ direction: Int) {
        if let id = ShellBlockNavigation.next(in: blocks.map(\.id), selected: store.shellSelectedBlockID, direction: direction) { select(id) }
    }
    private func attach(_ block: NativeBlock) {
        guard store.attachShellBlock(block) else { return }
        findFocused = false; findVisible = false; focus = UUID()
    }
    private func copy(_ kind: ShellBlockCopy) {
        guard let block = selectedBlock else { return }
        UIPasteboard.general.string = kind.text(block); copied = kind == .command ? "Command copied" : kind == .output ? "Output copied" : "Block copied"
    }
    private func openFind() {
        dismissCompletion()
        if selectedBlock == nil, let block = blocks.last { select(block.id) }
        guard selectedBlock != nil else { return }
        following = false; focus = nil; findVisible = true; findFocusRequest = UUID(); navigationRevision += 1
    }
    private func closeFind() { findVisible = false; findFocused = false; findQuery = ""; focusInput() }
    private func moveMatch(_ direction: Int) { matchIndex = search.index(after: matchIndex, direction: direction); navigationRevision += 1 }
    private func resumeFollowing() { store.shellSelectedBlockID = nil; findVisible = false; findFocused = false; following = !isExpanded; scrollRequest += 1 }

    private func handleTerminalShortcut(_ action: ShellTerminalShortcut) {
        guard canUseActions else { return }
        switch action {
        case .previous: moveBlock(-1)
        case .next: moveBlock(1)
        case .find: openFind()
        case .copyCommand: copy(.command)
        case .copyOutput: copy(.output)
        case .copyBoth: copy(.both)
        case .attach: if let selectedBlock { attach(selectedBlock) }
        }
    }

    private var blockToolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Button { moveBlock(-1) } label: { Image(systemName: "chevron.up").frame(width: 44, height: 44) }.accessibilityLabel("Previous command block").help("Previous block · ⌘⌥↑")
                Button { moveBlock(1) } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("Next command block").help("Next block · ⌘⌥↓")
                Text(selectedBlock.flatMap { block in blocks.firstIndex(where: { $0.id == block.id }).map { "Block \($0 + 1) of \(blocks.count)" } } ?? "\(blocks.count) command blocks")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Button { openFind() } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("Find in command output").help("Find in output · ⌘F")
                Menu {
                    Toggle("History suggestions", isOn: $historySuggestions)
                    Text("→ accepts all · ⌥→ accepts a word · Esc dismisses")
                } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                    .accessibilityLabel("Shell input settings").help("Shell input settings")
                if let selectedBlock {
                    Menu {
                        Button("Copy command · ⌘⌥C") { copy(.command) }
                        Button("Copy output · ⌘⇧C") { copy(.output) }
                        Button("Copy both · ⌘⌥⇧C") { copy(.both) }
                    } label: { Image(systemName: "doc.on.doc").frame(width: 44, height: 44) }.accessibilityLabel("Copy selected block")
                    Button { attach(selectedBlock) } label: { Label("Attach", systemImage: "paperclip").frame(minHeight: 44).padding(.horizontal, 8) }
                        .help("Attach selected block · ⌘⇧A").accessibilityIdentifier("attachSelectedBlock")
                    Button { resumeFollowing(); focusInput() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Clear block selection")
                }
                if let copied { Text(copied).font(.caption).foregroundStyle(theme.accent) }
            }.padding(.horizontal, 14).buttonStyle(.plain)
        }.scrollIndicators(.hidden).disabled(!store.currentInteractions.isEmpty)
    }
    private var findBar: some View {
        HStack(spacing: 8) {
            TextField("Find in command output", text: $findQuery).textFieldStyle(.roundedBorder).focused($findFocused)
                .onSubmit { moveMatch(1) }.accessibilityIdentifier("shellFindField")
                .task(id: findFocusRequest) {
                    findFocused = false
                    await Task.yield()
                    if !Task.isCancelled && findVisible { findFocused = true }
                }
            Text(findQuery.isEmpty ? "Output" : search.matches.isEmpty ? "No matches" : "\(min(matchIndex + 1, search.matches.count)) / \(search.matches.count)\(search.limited ? "+" : "")")
                .font(.caption.monospaced()).fixedSize().accessibilityIdentifier("shellFindCount")
            Button { moveMatch(-1) } label: { Image(systemName: "chevron.up").frame(width: 44, height: 44) }.accessibilityLabel("Previous match").disabled(search.matches.isEmpty)
            Button { moveMatch(1) } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("Next match").disabled(search.matches.isEmpty)
            Button { closeFind() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Close find")
        }.padding(.horizontal, 20).padding(.bottom, 8).buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
    }
    private var keyboardActions: some View {
        Group {
            Button("Previous block") { moveBlock(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next block") { moveBlock(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Find output") { openFind() }.keyboardShortcut("f", modifiers: .command)
            if selectedBlock != nil {
                Button("Copy command") { copy(.command) }.keyboardShortcut("c", modifiers: [.command, .option])
                Button("Copy output") { copy(.output) }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Copy block") { copy(.both) }.keyboardShortcut("c", modifiers: [.command, .option, .shift])
                Button("Attach block") { if let selectedBlock { attach(selectedBlock) } }.keyboardShortcut("a", modifiers: [.command, .shift])
            }
            if findVisible {
                Button("Next match") { moveMatch(1) }.keyboardShortcut("g", modifiers: .command)
                Button("Previous match") { moveMatch(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Close find") { closeFind() }.keyboardShortcut(.escape, modifiers: [])
            }
        }.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
    /// Pane focus and maximize are owned only by the active pane so exactly one
    /// registration exists per chord, independent of the block-action
    /// conditions above. iPad hardware keyboards have no Mac menu, so hidden
    /// buttons are the only handler there and on Mac Catalyst.
    private var paneActions: some View {
        Group {
            Button("Focus pane left") { focusPane(.left) }.keyboardShortcut(.leftArrow, modifiers: [.control, .option])
            Button("Focus pane right") { focusPane(.right) }.keyboardShortcut(.rightArrow, modifiers: [.control, .option])
            Button("Focus pane above") { focusPane(.up) }.keyboardShortcut(.upArrow, modifiers: [.control, .option])
            Button("Focus pane below") { focusPane(.down) }.keyboardShortcut(.downArrow, modifiers: [.control, .option])
            Button("Maximize pane") { maximizePane() }.keyboardShortcut("m", modifiers: [.command, .shift])
        }.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
}

/// Commands stay open in both presentations; output is never behind a disclosure.
struct NativeCommandCell: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var store: PocketStore
    @Environment(\.harnessTheme) private var theme
    @Environment(\.agentPaneIsActive) private var active
    @Environment(\.nativeTerminalHeight) private var terminalHeight
    let block: NativeBlock
    let terminal: Bool
    var selected = false
    var select: (() -> Void)? = nil
    var attach: (() -> Void)? = nil
    var find: (() -> Void)? = nil
    var blockShortcut: ((ShellTerminalShortcut) -> Void)? = nil
    var search: ShellBlockSearch? = nil
    var activeMatch: ShellSearchMatch? = nil
    var searchRevision = 0
    @State private var revision = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let select {
                    Button(action: select) { Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right").foregroundStyle(theme.accent).frame(width: 32, height: 44) }
                        .buttonStyle(.plain).accessibilityLabel("Select command block: " + block.command)
                } else { Text("❯").foregroundStyle(theme.accent) }
                Text(block.command).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if block.interrupted { Text("interrupted · exit unknown").foregroundStyle(.orange).font(.caption.monospaced()) }
                else if let code = block.exitCode { Text("exit \(code)").foregroundStyle(code == 0 ? .secondary : Color.orange).font(.caption.monospaced()) }
                else if !block.finished { Text("running").foregroundStyle(.secondary).font(.caption.monospaced()) }
            }.font(.system(size: 14, weight: .medium, design: .monospaced))
            Text(block.directory).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let search {
                ShellFindOutput(block: block, search: search, activeMatch: activeMatch, revision: searchRevision)
            } else if !block.finished, let client = store.nativeShell {
                NativeTerminalView(client: client, focus: active && terminal, revision: revision, askAgent: {
                    Task { await store.askFromShell(store.draft.isEmpty ? "Inspect this running terminal command and explain its current output without executing more commands." : store.draft, block: nil) }
                }, blockShortcut: blockShortcut).frame(height: terminalHeight)
            } else if !block.preview.isEmpty {
                ScrollView(.horizontal) {
                    Text(block.attributedOutput(appearance: TerminalAppearance(theme: theme, scheme: scheme)))
                        .fontDesign(nil) // Do not replace the symbol font with the app-wide theme design.
                        .lineSpacing(3)
                        .fixedSize(horizontal: true, vertical: true).textSelection(.enabled)
                }.scrollIndicators(.hidden)
            }
            if block.truncated { Text("Earlier output exceeded the retained buffer.").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 18) {
                Button("Copy output") { UIPasteboard.general.string = block.preview }
                Button("Attach to question") {
                    if let attach { attach() }
                    else if store.attachShellBlock(block) { store.composerFocusRequest = UUID() }
                }
            }.font(.caption2).foregroundStyle(.secondary).frame(minHeight: 32)
        }.padding(terminal ? 0 : 14).frame(maxWidth: .infinity, alignment: .leading)
            .background { if !terminal { RoundedRectangle(cornerRadius: 12).fill(theme.surface.opacity(0.55)) } }
            .background { if selected { RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.06)).padding(-8) } }
            .overlay { if selected { RoundedRectangle(cornerRadius: 8).stroke(theme.accent.opacity(0.65), lineWidth: 1).padding(-8).allowsHitTesting(false) } }
            .contextMenu {
                if let select { Button("Select block", action: select) }
                ForEach(ShellBlockCopy.allCases, id: \.self) { kind in Button(kind.rawValue) { UIPasteboard.general.string = kind.text(block) } }
                Button("Attach to question") { if let attach { attach() } else { store.attachShellBlock(block) } }
                if let find { Button("Find in output", action: find) }
            }
    }
}

private struct NativeTerminalHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 360 }
extension EnvironmentValues {
    var nativeTerminalHeight: CGFloat {
        get { self[NativeTerminalHeightKey.self] }
        set { self[NativeTerminalHeightKey.self] = newValue }
    }
}

