import SwiftUI
import UIKit

struct HarnessView: View {
    @Environment(\.nativePanelTerminal) private var nativePanelTerminal
    @Environment(\.harnessTheme) private var theme
    @EnvironmentObject var store: PocketStore
    @Environment(\.agentPaneIsActive) private var activePane
    @State private var stickToBottom = true
    @State private var scrollRequest = 0
    @State private var connection = false
    @State private var appearance = false
    @State private var modelPalette = false
    @State private var commandIndex = 0
    @State private var commandsDismissed = false
    @State private var creatingTask = false
    /// One composer-palette row. A local entry carries no catalog descriptor;
    /// a row the session's catalog serves carries it, so the run path can tell
    /// a command that claims an argument from a bare one.
    private struct CommandSuggestion {
        var name: String
        var detail: String
        var descriptor: CommandDescriptor?
    }
    private let localCommands = [("/view", "Switch chat / terminal"), ("/model", "Search models"), ("/new", "New task in default workspace"), ("/compact", "Compact model context")]
    private var commandPaletteVisible: Bool {
        !commandsDismissed && store.draft.hasPrefix("/") && !store.draft.contains(where: { $0.isWhitespace })
    }
    /// The palette rows: the local entries first, then the session's catalog
    /// snapshot, deduped by name with the local entry winning - /compact is a
    /// native editor action as well as a host command, and it stays ours.
    private var commandMatches: [CommandSuggestion] {
        guard commandPaletteVisible else { return [] }
        let query = store.draft.lowercased()
        var rows = localCommands.map { CommandSuggestion(name: $0.0, detail: $0.1, descriptor: nil) }
        let localNames = Set(rows.map(\.name))
        for descriptor in store.commandCatalog.sorted(by: { $0.name < $1.name }) {
            let name = "/" + descriptor.name
            guard !localNames.contains(name) else { continue }
            // The reference shows the input hint when the command declares one
            // (dsh-client-ui-commands client.js:643); the description is the
            // fallback for a command with no input line.
            let hint = descriptor.input?.hint ?? ""
            rows.append(CommandSuggestion(name: name, detail: hint.isEmpty ? descriptor.description : hint, descriptor: descriptor))
        }
        return rows.filter { $0.name.hasPrefix(query) }
    }
    /// A cold or warming catalog has no rows to render yet; it says so instead
    /// of leaving the palette empty (the native harness has no host catalog).
    private var catalogStatus: String? {
        guard !store.usesNativeHarness else { return nil }
        switch store.commandCatalogState {
        case .cold, .pending: return "Loading commands..."
        case .failed: return "Commands unavailable"
        case .ready: return nil
        }
    }
    private func runCommand(_ suggestion: CommandSuggestion) {
        guard !creatingTask else { return }
        switch suggestion.name {
        case "/compact": Task { await store.compactContext(fromEditor: true) }
        case "/view": store.draft = ""; terminalInput.toggle(); store.composerFocusRequest = UUID()
        case "/model":
            store.draft = ""
            if store.usesNativeHarness { store.error = "Native Harness uses the model configured on its host: " + store.modelLabel }
            else { modelPalette = true }
        case "/new":
            guard store.connected else { return }
            store.draft = ""; creatingTask = true
            Task { await store.createDefaultTask(); creatingTask = false }
        default:
            guard let descriptor = suggestion.descriptor else { return }
            // A command that declares an input line claims the composer with
            // its leading token; a bare command runs at once (reference
            // dispatch, dsh-client-ui-commands client.js:682-688). The store
            // refuses attachments the command does not admit.
            if descriptor.input != nil {
                store.draft = suggestion.name + " "
                store.composerFocusRequest = UUID()
            } else {
                store.draft = suggestion.name
                Task { await store.executeCommand(suggestion.name) }
            }
        }
    }
    private func moveCommand(_ delta: Int) {
        guard !commandMatches.isEmpty else { return }
        commandIndex = (commandIndex + delta + commandMatches.count) % commandMatches.count
    }
    private func completeCommand() {
        guard !commandMatches.isEmpty else { return }
        store.draft = commandMatches[min(commandIndex, commandMatches.count - 1)].name
    }
    @AppStorage("harness.terminalInput") private var savedTerminalInput = false
    private var terminalInput: Bool {
        get { store.usesNativeHarness ? false : savedTerminalInput }
        nonmutating set {
            if store.usesNativeHarness { nativePanelTerminal?.wrappedValue = newValue }
            else { savedTerminalInput = newValue }
        }
    }
    @FocusState private var composerFocused: Bool
    private var desktopComposer: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
    private var terminalInset: CGFloat { desktopComposer ? 24 : 16 }
    private var contentWidth: CGFloat {
        #if targetEnvironment(macCatalyst)
        terminalInput ? .infinity : 900
        #else
        desktopComposer && !terminalInput ? 900 : .infinity
        #endif
    }
    private var canSend: Bool {
        (!store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.images.isEmpty) && !store.submitting && !store.preparingImages && !store.selectingModel && store.connected && store.selectedID != nil
    }
    private func sendPrompt() {
        if !commandMatches.isEmpty {
            runCommand(commandMatches[min(commandIndex, commandMatches.count - 1)]); return
        }
        let command = store.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let local = localCommands.first(where: { $0.0 == command }) {
            runCommand(CommandSuggestion(name: local.0, detail: local.1, descriptor: nil)); return
        }
        // A catalog command line: a command declaring an input line submits the
        // line as typed, a bare one only while nothing follows the name
        // (reference matchEnter, dsh-client-ui-commands client.js:712-758), and
        // the store refuses attachments the command does not admit. A cold
        // catalog resolves nothing, so the line stays an ordinary message -
        // exactly the composer's behaviour before the catalog existed.
        if let descriptor = store.resolvedCommand(command),
           descriptor.input != nil || !command.contains(where: { $0.isWhitespace }) {
            Task { await store.executeCommand(command) }
            return
        }
        guard canSend else { return }
        #if !targetEnvironment(macCatalyst)
        composerFocused = false
        #endif
        stickToBottom = true; scrollRequest += 1
        Task { await store.submit() }
    }
    private func resumeFollowing() {
        stickToBottom = true
        scrollRequest += 1
        if activePane && !modelPalette && !connection && !appearance { store.composerFocusRequest = UUID() }
    }
    var body: some View {
        VStack(spacing: 0) {
            if !store.connected {
                Button { connection = true } label: { Label(store.connecting ? "Reconnecting…" : "Not connected · tap to connect", systemImage: "wifi.exclamationmark").font(.caption).padding(10).frame(maxWidth: .infinity) }
                    .background(.orange.opacity(0.1))
            }
            if store.usesNativeHarness { ContextStatusView() }
            ScrollViewReader { proxy in
                ScrollView {
                    // Exact heights prevent estimated lazy-row sizes from feeding back
                    // into scrollTo while a streamed message is growing.
                    VStack(alignment: .leading, spacing: 25) {
                        if store.hasMore { Button("Load earlier messages") { Task { await store.loadOlder() } }.font(.caption).frame(maxWidth: .infinity).disabled(store.loadingHistory) }
                        if store.loadingHistory && store.rows.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(40) }
                        if !store.loadingHistory && store.rows.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "sparkle").font(.system(size: 30, weight: .light)).foregroundStyle(theme.accent)
                                Text("What shall we do?").font(.system(size: 30, weight: .semibold))
                                Text("Describe a task. Your agent will get to work on your Mac.").foregroundStyle(.secondary)
                            }.padding(.vertical, 65)
                        }
                        ForEach(store.rows) { row in TranscriptCell(row: row, sessionID: store.selectedID ?? "", terminal: terminalInput) }
                        if let pending = store.pendingText {
                            Group {
                                if terminalInput {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("❯ YOU · sending").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(theme.accent)
                                        Text(pending).font(.system(size: theme.messageSize, design: .monospaced)).textSelection(.enabled).modifier(HarnessTextLegibility())
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    VStack(alignment: .trailing, spacing: 5) { Text(pending).padding(14).harnessSurface(radius: 20); Text("Waiting for confirmation").font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            }
                        }
                        if store.running && !store.compactingContext {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 9) { ProgressView().controlSize(.small); Text("Agent is working").font(.caption).foregroundStyle(.secondary) }
                                if let reasoning = store.liveReasoning {
                                    LiveReasoningView(text: reasoning.text, compact: true, terminal: terminalInput).id(reasoning.id).frame(maxWidth: terminalInput ? .infinity : 520, alignment: .leading)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom").accessibilityElement().accessibilityLabel("End of conversation").accessibilityIdentifier("transcriptBottom")
                    }.padding(.horizontal, terminalInput ? terminalInset : 22).padding(.vertical, terminalInput ? 16 : 24)
                        .frame(maxWidth: contentWidth).frame(maxWidth: .infinity)
                        .background { GeometryReader { geometry in Color.clear.preference(key: ConversationContentHeight.self, value: geometry.size.height) } }
                }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("transcriptScroll")
                    .modifier(ReadingScrollObserver(onScroll: { stickToBottom = false }, onBottom: resumeFollowing))
                    .background { GeometryReader { geometry in Color.clear.preference(key: ConversationViewportHeight.self, value: geometry.size.height) } }
                    .onPreferenceChange(ConversationContentHeight.self) { _ in if stickToBottom { scrollRequest += 1 } }
                    .onPreferenceChange(ConversationViewportHeight.self) { _ in if stickToBottom { scrollRequest += 1 } }
                    .onAppear { scrollRequest += 1 }
                    .onChange(of: store.selectedID) { _, _ in stickToBottom = true; scrollRequest += 1 }
                    .onChange(of: store.rows) { _, _ in if stickToBottom { scrollRequest += 1 } }
                    .onChange(of: store.loadingHistory) { old, new in if old && !new && stickToBottom { scrollRequest += 1 } }
                    .task(id: scrollRequest) {
                        // Scroll after layout, including image decoding and composer/keyboard resizing.
                        // Coalesce streamed chunks and let layout settle between scrolls.
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                        guard !Task.isCancelled, stickToBottom else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !stickToBottom { Button { resumeFollowing() } label: { Image(systemName: "arrow.down").padding(12).background(.regularMaterial, in: Circle()) }.padding(16).accessibilityLabel("Jump to latest message") }
                    }
            }.clipped()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !terminalInput { bottomPanel }
                }
            // Terminal output and input occupy separate layout regions: the
            // transcript must never paint underneath the unboxed prompt.
            if terminalInput { bottomPanel }

        }.background { ThemeBackdrop() }
            .onAppear { if activePane { store.composerFocusRequest = UUID() } }
            .onChange(of: activePane) { _, active in if active { store.composerFocusRequest = UUID() } }
            #if !targetEnvironment(macCatalyst)
            .navigationTitle(store.selected?.title ?? "New task").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Reconnect", systemImage: "arrow.clockwise") { Task { await store.connect() } }
                        Button("Appearance", systemImage: "paintpalette") { appearance = true }
                        Button("Connection", systemImage: "network") { connection = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                }
            }
            #endif
            .sheet(isPresented: $appearance) { AppearanceView() }.sheet(isPresented: $connection) { ConnectionView() }
            .sheet(isPresented: $modelPalette, onDismiss: { store.composerFocusRequest = UUID() }) { ModelPaletteView().environmentObject(store).environment(\.harnessTheme, theme) }
            .onChange(of: terminalInput) { _, _ in
                store.readingMode = false
                store.composerFocusRequest = UUID()
            }
            .onChange(of: store.draft) { _, text in
                commandIndex = 0; commandsDismissed = false
            }
    }
    private var bottomPanel: some View {
        VStack(spacing: 0) {
            if let error = store.error { HStack { Text(error).font(.caption).foregroundStyle(.orange); Spacer(); Button { store.error = nil } label: { Image(systemName: "xmark").font(.caption) } }.padding(.horizontal, 20).padding(.vertical, 8) }
            if let interaction = store.currentInteractions.first { InteractionView(item: interaction).id(interaction.id).frame(maxWidth: 560).frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.bottom, 8) }
            if store.usesNativeHarness { QueueDockView().padding(.horizontal, 16).padding(.bottom, 8) }
            if store.usesNativeHarness { HStack { DiffReviewButton(); Spacer(minLength: 0) }.padding(.horizontal, 16).padding(.bottom, 8) }
            if !store.currentQueue.isEmpty {
                DisclosureGroup("Queued: \(store.currentQueue.count)") {
                    ForEach(store.currentQueue, id: \.pretty) { item in Text(JSON.text(item["message"]["content"])).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) }
                }.font(.caption).padding(.horizontal, 22).padding(.bottom, 8)
            }
            if store.readingMode {
                Button {
                    store.readingMode = false
                    store.composerFocusRequest = UUID()
                } label: {
                    HStack {
                        Image(systemName: "square.and.pencil")
                        Text(store.draft.isEmpty ? "Reply…" : store.draft).lineLimit(1)
                        Spacer()
                        Text(store.modelLabel).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.up")
                    }.padding(.horizontal, 18).frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityIdentifier("expandComposer")
            }
            composer.frame(height: store.readingMode ? 0 : nil).clipped()
                .opacity(store.readingMode ? 0 : 1).allowsHitTesting(!store.readingMode)
                .accessibilityHidden(store.readingMode)
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: terminalInput ? 10 : 13) {
            if store.usesNativeHarness { ShellAttachmentStrip() }
            if terminalInput {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(theme.accent)
                    Text(store.selected?.cwd ?? "~").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(store.usesNativeHarness ? "Native" : "DSH").foregroundStyle(theme.accent)
                }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            if commandPaletteVisible && (!commandMatches.isEmpty || catalogStatus != nil) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(commandMatches.enumerated()), id: \.element.name) { index, command in
                        Button { runCommand(command) } label: {
                            HStack(spacing: 12) {
                                Text(index == commandIndex ? "❯" : " ").foregroundStyle(theme.accent)
                                Text(command.name).frame(minWidth: 68, alignment: .leading)
                                Text(command.detail).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }.font(.system(size: 13, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 8)
                                .background(index == commandIndex ? theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).disabled(creatingTask).accessibilityIdentifier("command" + command.name)
                    }
                    if let catalogStatus {
                        Text(catalogStatus).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    Text("↑↓ choose · Tab complete · Enter run · Esc dismiss").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4)
                }.fontDesign(.monospaced).padding(6).background(theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: 540, alignment: .leading)
            }
            if creatingTask { ProgressView("Creating task…").font(.caption) }
            ImageComposer().disabled(store.usesNativeHarness).help(store.usesNativeHarness ? "Native image input is not yet supported" : "Attach images")
            if !desktopComposer { VoiceComposer().disabled(store.usesNativeHarness) }
            if !terminalInput { promptInput }
            HStack(spacing: 10) {
                Menu {
                    Text("DSH will also use this model for new tasks")
                    ForEach(store.catalog["groups"].array, id: \.pretty) { group in
                        Section(group["name"].string) {
                            ForEach(group["models"].array, id: \.pretty) { model in
                                Button { Task { await store.selectModel(provider: group["id"].string, model: model["id"].string) } } label: {
                                    if store.model["provider"].string == group["id"].string && store.model["model"].string == model["id"].string {
                                        Label(model["name"].string, systemImage: "checkmark")
                                    } else { Text(model["name"].string) }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) { Image(systemName: "cpu"); Text(store.modelLabel).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }.font(.caption).foregroundStyle(.secondary)
                }.disabled(!store.connected || store.selectingModel || store.usesNativeHarness)
                if store.selectingModel { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button {
                    terminalInput.toggle()
                    store.composerFocusRequest = UUID()
                } label: {
                    if terminalInput { Text("/view").font(.system(size: 11, design: .monospaced)) }
                    else { Image(systemName: "terminal").font(.system(size: 14)) }
                }.foregroundStyle(.secondary).accessibilityLabel(terminalInput ? "Switch to chat input" : "Switch to terminal input").accessibilityIdentifier("toggleInputView").help("Toggle input style · /view")
                if store.running {
                    Button { Task { await store.cancel() } } label: { Image(systemName: "stop.fill").font(.system(size: 12)).frame(width: 36, height: 36).background(Color.primary.opacity(0.08), in: Circle()) }.accessibilityLabel("Stop agent").disabled(!store.connected)
                }
                if desktopComposer { VoiceComposer(compact: true).disabled(store.usesNativeHarness).help(store.usesNativeHarness ? "Native voice input is not yet supported" : "Hold to record").fixedSize(horizontal: true, vertical: false) }
                Button {
                    sendPrompt()
                } label: { Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold)).frame(width: 38, height: 38).background(theme.accent, in: Circle()).foregroundStyle(theme.canvas) }
                    .disabled(!canSend)
                    .opacity(store.draft.isEmpty && store.images.isEmpty ? 0.3 : 1).accessibilityLabel("Send").accessibilityIdentifier("sendPrompt")
                    .contextMenu { if store.running && (!store.usesNativeHarness || store.nativeSupportsQueue) { Button("Steer current turn") { Task { await store.submit(mode: "steer") } } } }
            }
            if terminalInput { promptInput }
        }.padding(terminalInput ? 0 : 16)
            .modifier(HarnessComposerSurface(enabled: !terminalInput))
            .padding(.horizontal, terminalInput ? terminalInset : 14)
            .padding(.top, terminalInput ? 12 : 6).padding(.bottom, terminalInput ? 16 : 10)
            .frame(maxWidth: contentWidth).frame(maxWidth: .infinity)
    }
    private var promptInput: some View {
            HStack(alignment: .top, spacing: 8) {
            if terminalInput { Text("❯").font(.system(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(theme.accent).padding(.top, desktopComposer ? 8 : 0).accessibilityHidden(true) }
            if desktopComposer {
            DesktopPromptEditor(text: $store.draft, focusRequest: $store.composerFocusRequest, collapsed: store.readingMode, ink: theme.ink, monospaced: terminalInput, textSize: theme.messageSize, textShadow: theme.glassSettings.shadow, suggestionsVisible: !commandMatches.isEmpty, moveSuggestion: moveCommand, completeSuggestion: completeCommand, dismissSuggestions: { commandsDismissed = true }, sendToAgent: store.currentInteractions.isEmpty ? sendPrompt : nil, send: sendPrompt)
                .fixedSize(horizontal: false, vertical: true)
            } else {
            TextField(terminalInput ? "Message agent… /model · /view" : "Give your agent a task…", text: $store.draft, axis: .vertical)
                .lineLimit(1...7).font(.system(size: theme.messageSize, design: terminalInput ? .monospaced : theme.design)).modifier(HarnessTextLegibility()).focused($composerFocused).accessibilityIdentifier("composer")
                .task(id: store.composerFocusRequest) {
                    if store.composerFocusRequest != nil { composerFocused = true; store.composerFocusRequest = nil }
                }
            }
            }
    }

}
struct TranscriptCell: View {
    @EnvironmentObject private var store: PocketStore
    @Environment(\.harnessTheme) private var theme
    let row: TranscriptRow
    let sessionID: String
    var terminal = false
    @State private var showDiff = false
    var body: some View {
        if terminal && (row.kind == .user || row.kind == .assistant) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(row.kind == .user ? "❯" : "◆").foregroundStyle(theme.accent)
                    Text(row.kind == .user ? "YOU" : "DSH").foregroundStyle(.secondary)
                }.font(.system(size: 11, weight: .semibold, design: .monospaced))
                if !row.text.isEmpty {
                    if row.kind == .assistant { AssistantMarkdown(text: row.text, terminal: true) }
                    else { Text(row.text).font(.system(size: theme.messageSize, design: .monospaced)).lineSpacing(5).textSelection(.enabled).modifier(HarnessTextLegibility()) }
                }
                ForEach(Array(row.images.enumerated()), id: \.offset) { _, ref in
                    RemoteAttachment(reference: ref, sessionID: sessionID)
                }
                if row.kind == .user && row.id.hasPrefix("native-user-") && !row.detail.isEmpty { ShellSentContext(text: row.detail) }
            }.frame(maxWidth: .infinity, alignment: .leading).fontDesign(.monospaced)
        } else {
            standardContent.fontDesign(terminal ? .monospaced : theme.design)
        }
    }
    @ViewBuilder private var standardContent: some View {
        switch row.kind {
        case .user:
            HStack { Spacer(minLength: 35); VStack(alignment: .leading, spacing: 10) {
                ForEach(row.images, id: \.pretty) { ref in RemoteAttachment(reference: ref, sessionID: sessionID) }
                if !row.text.isEmpty { Text(row.text).font(.system(size: theme.messageSize, design: theme.design)).textSelection(.enabled).modifier(HarnessTextLegibility()) }
                if row.id.hasPrefix("native-user-") && !row.detail.isEmpty { ShellSentContext(text: row.detail) }
            }.padding(13).harnessSurface(radius: 21) }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if !row.text.isEmpty { AssistantMarkdown(text: row.text) }
                ForEach(Array(row.images.enumerated()), id: \.offset) { _, ref in RemoteAttachment(reference: ref, sessionID: sessionID) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .reasoning:
            if terminal {
                VStack(alignment: .leading, spacing: 8) {
                    Label(row.complete ? "Reasoning" : "Thinking…", systemImage: "sparkle").font(.caption).foregroundStyle(.secondary)
                    Text(row.text).font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                DisclosureGroup { Text(row.text).font(.system(size: 15, design: theme.design)).foregroundStyle(.secondary).textSelection(.enabled) } label: { Label(row.complete ? "Reasoning" : "Thinking…", systemImage: "sparkle").font(.caption).foregroundStyle(.secondary) }
            }
        case .tool:
            VStack(alignment: .leading, spacing: 10) {
                if terminal {
                    toolHeading
                    Text(row.detail).font(.system(size: 13, design: .monospaced)).lineSpacing(3)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("inlineToolOutput")
                } else {
                    DisclosureGroup {
                        ScrollView(.horizontal) { Text(row.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(.top, 8) }.frame(maxHeight: 250)
                    } label: { toolHeading }
                }
                if !row.diffs.isEmpty {
                    Button("View changes", systemImage: "doc.text.magnifyingglass") { showDiff = true }
                        .font(.caption).accessibilityIdentifier("viewDiff")
                        .sheet(isPresented: $showDiff) { ToolDiffView(diffs: row.diffs) }
                }
                ForEach(Array(row.images.enumerated()), id: \.offset) { _, ref in
                    RemoteAttachment(reference: ref, sessionID: sessionID)
                }
            }.padding(terminal ? 0 : 13)
                .background { if !terminal { RoundedRectangle(cornerRadius: 13).fill(theme.surface.opacity(0.65)) } }
        case .shell:
            if let block = row.shell { NativeCommandCell(block: block, terminal: terminal) }
        case .notice: Label(row.text, systemImage: "info.circle").font(.caption).foregroundStyle(row.failed ? .orange : .secondary)
        }
    }
    private var toolHeading: some View {
        HStack(spacing: 9) {
            Image(systemName: row.failed ? "exclamationmark.circle" : row.complete ? "checkmark.circle" : "terminal")
            Text(row.text).font(.system(size: 13, design: .monospaced))
        }.foregroundStyle(row.failed ? .orange : .secondary)
    }
}
struct InteractionView: View {
    @Environment(\.harnessTheme) private var theme
    @EnvironmentObject var store: PocketStore
    @Environment(\.agentPaneIsActive) private var activePane
    @State private var confirmFullAccess = false
    let item: Interaction
    var decisionHandler: ((JSON) -> Void)? = nil
    @State private var answers: [String: String] = [:]
    @State private var selected: [String: Set<String>] = [:]
    @State private var busy = false
    var questions: [JSON] { item.request["questions"].array }
    var ready: Bool { questions.allSatisfy { !(answers[$0["id"].string] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(selected[$0["id"].string] ?? []).isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(item.isApproval ? "Permission required" : "Your agent has a question", systemImage: item.isApproval ? "hand.raised" : "bubble.left.and.bubble.right").font(.subheadline.weight(.semibold))
                Spacer()
                if store.currentInteractions.count > 1 { Text("1 of \(store.currentInteractions.count)").font(.caption).foregroundStyle(.secondary) }
            }
            if item.isApproval {
                Text(item.request["toolName"].string).font(.system(.subheadline, design: .monospaced))
                if !item.request["reason"].string.isEmpty { Text(item.request["reason"].string).font(.caption).lineLimit(3).textSelection(.enabled) }
                DisclosureGroup("Action details") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if !item.request["reason"].string.isEmpty { Text(item.request["reason"].string).font(.caption).textSelection(.enabled) }
                            if let call = store.rows.first(where: { $0.id == "tool-" + item.request["callId"].string }) {
                                Text(call.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180)
                }.font(.caption)
                ViewThatFits(in: .horizontal) {
                    approvalButtons
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Allow once") { answer(.string("allowed-once")) }.buttonStyle(.borderedProminent)
                        Button("Reject") { answer(.string("rejected")) }.buttonStyle(.bordered)
                        Button("Full access…") { confirmFullAccess = true }.disabled(!store.supportsFullAccess)
                    }
                }
                if activePane { Text(store.supportsFullAccess ? "⌘↵ Allow once · ⌘⌫ Reject · ⌘⇧A Full access" : "⌘↵ Allow once · ⌘⌫ Reject").font(.caption2).foregroundStyle(.secondary) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(questions, id: \.pretty) { q in
                            let id = q["id"].string
                            Text(q["question"].string).font(.callout.weight(.medium))
                            if !q["detail"].string.isEmpty { Text(.init(q["detail"].string)).font(.caption).textSelection(.enabled) }
                            ForEach(q["options"].array, id: \.pretty) { option in
                                let label = option["label"].string
                                Button {
                                    var set = selected[id] ?? []
                                    if set.contains(label) { set.remove(label) } else if q["multiSelect"].bool { set.insert(label) } else { set = [label] }
                                    selected[id] = set
                                } label: { HStack { Image(systemName: (selected[id] ?? []).contains(label) ? "checkmark.circle.fill" : "circle"); VStack(alignment: .leading) { Text(label); if !option["description"].string.isEmpty { Text(option["description"].string).font(.caption).foregroundStyle(.secondary) } } }.font(.callout) }
                            }
                            TextField("Your answer", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }), axis: .vertical).textFieldStyle(.roundedBorder)
                        }
                    }
                }.frame(maxHeight: 240)
                Button("Reply") {
                    let data = questions.map { q -> JSON in let id = q["id"].string; var a: [String: JSON] = ["id": .string(id), "selected": .array((selected[id] ?? []).sorted().map(JSON.string))]; if let text = answers[id], !text.isEmpty { a["custom"] = .string(text) }; return .object(a) }
                    answer(.object(["answers": .array(data)]))
                }.buttonStyle(.borderedProminent).tint(theme.accent).disabled(!ready)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18)).disabled(busy || !store.connected)
        .background {
            if activePane && item.isApproval {
                Button("") { answer(.string("allowed-once")) }.keyboardShortcut(.return, modifiers: .command).hidden().disabled(busy || !store.connected)
                Button("") { answer(.string("rejected")) }.keyboardShortcut(.delete, modifiers: .command).hidden().disabled(busy || !store.connected)
                Button("") { confirmFullAccess = true }.keyboardShortcut("a", modifiers: [.command, .shift]).hidden().disabled(busy || !store.connected || !store.supportsFullAccess)
            }
        }
        .alert("Enable full access for this session?", isPresented: $confirmFullAccess) {
            Button("Cancel", role: .cancel) {}
            Button("Enable and allow this request", role: .destructive) {
                busy = true
                Task {
                    if await store.enableFullAccess(for: item) { await store.answer(item, value: .string("allowed-once")) }
                    busy = false
                }
            }
        } message: {
            Text("The agent may change files and run external commands without further permission prompts in this session. Other sessions are unchanged.")
        }
    }
    private var approvalButtons: some View {
        HStack(spacing: 10) {
            Button("Allow once") { answer(.string("allowed-once")) }.buttonStyle(.borderedProminent).tint(theme.accent)
            Button("Reject") { answer(.string("rejected")) }.buttonStyle(.bordered)
            Button("Full access…") { confirmFullAccess = true }.disabled(!store.supportsFullAccess).buttonStyle(.borderless)
        }
    }
    private func answer(_ value: JSON) { guard !busy, store.connected else { return }; if let decisionHandler { decisionHandler(value); return }; busy = true; Task { await store.answer(item, value: value); busy = false } }
}

struct ConversationContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ConversationViewportHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct DesktopPromptEditor: UIViewRepresentable {
    @Environment(\.agentPaneActivate) private var activatePane
    @Binding var text: String
    @Binding var focusRequest: UUID?
    let collapsed: Bool
    let ink: Color
    var monospaced = false
    var textSize: CGFloat = 16
    var textShadow: Double = 0
    var suggestionsVisible = false
    var moveSuggestion: (Int) -> Void = { _ in }
    var completeSuggestion: () -> Void = {}
    var dismissSuggestions: () -> Void = {}
    var accessibilityName = "Give your agent a task"
    var accessibilityID = "composer"
    var sendToAgent: (() -> Void)? = nil
    var interruptCommand: (() -> Void)? = nil
    var yieldFocusOnSend = false
    var allowsRequestedFocus = true
    var shellCompletion: ((String, NSRange) -> Void)? = nil
    var shellHistory: ((Int, String, NSRange) -> ShellEditorEdit?)? = nil
    var shellSelectionChanged: ((String, NSRange) -> Void)? = nil
    var shellEdit: ShellEditorEdit? = nil
    var shellSuggestion: ((String) -> String?)? = nil
    let send: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> DesktopPromptTextView {
        let view = DesktopPromptTextView()
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 16)
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = accessibilityID
        view.accessibilityLabel = accessibilityName
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: DesktopPromptTextView, context: Context) {
        context.coordinator.parent = self
        view.sendPrompt = send
        view.sendToAgent = sendToAgent
        view.interruptCommand = interruptCommand
        view.yieldFocusOnSend = yieldFocusOnSend
        view.allowsRequestedFocus = allowsRequestedFocus
        view.shellCompletion = shellCompletion
        view.shellHistory = shellHistory
        view.shellSuggestion = shellSuggestion
        if !allowsRequestedFocus { view.pendingInitialFocus = false }
        view.suggestionsVisible = suggestionsVisible
        view.moveSuggestion = moveSuggestion
        view.completeSuggestion = completeSuggestion
        view.dismissSuggestions = dismissSuggestions
        if collapsed && view.isFirstResponder { view.resignFirstResponder() }
        let font: UIFont = monospaced ? .monospacedSystemFont(ofSize: textSize, weight: .regular) : .systemFont(ofSize: textSize)
        if view.font != font { view.font = font }
        view.smartQuotesType = monospaced ? .no : .default
        view.smartDashesType = monospaced ? .no : .default
        view.autocorrectionType = monospaced ? .no : .default
        view.spellCheckingType = monospaced ? .no : .default
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = Float(textShadow)
        view.layer.shadowRadius = textShadow > 0 ? 2 : 0
        view.layer.shadowOffset = CGSize(width: 0, height: 1)
        view.textColor = UIColor(ink)
        if let edit = shellEdit, view.lastShellEdit != edit.id {
            view.lastShellEdit = edit.id
            if view.text == edit.original && view.selectedRange == edit.selection {
                view.text = edit.text; view.selectedRange = NSRange(location: edit.cursor, length: 0)
            }
        }
        if view.text != text { view.text = text }
        if allowsRequestedFocus, let focusRequest, view.lastFocusRequest != focusRequest {
            view.focusApplied = { if self.focusRequest == focusRequest { self.focusRequest = nil } }
            view.lastFocusRequest = focusRequest
            view.pendingInitialFocus = true
            view.applyPendingFocus()
        }
        view.refreshAutosuggestion()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DesktopPromptTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(120, max(40, measured.height)))
    }
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: DesktopPromptEditor
        init(_ parent: DesktopPromptEditor) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.activatePane(); (textView as? DesktopPromptTextView)?.refreshAutosuggestion() }
        func textViewDidEndEditing(_ textView: UITextView) { (textView as? DesktopPromptTextView)?.refreshAutosuggestion() }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? DesktopPromptTextView)?.refreshAutosuggestion()
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.shellSelectionChanged?(textView.text, textView.selectedRange)
            (textView as? DesktopPromptTextView)?.refreshAutosuggestion()
        }
    }
}
final class DesktopPromptTextView: UITextView {
    var sendPrompt: (() -> Void)?
    var sendToAgent: (() -> Void)?
    var interruptCommand: (() -> Void)?
    var yieldFocusOnSend = false
    var allowsRequestedFocus = true
    var shellCompletion: ((String, NSRange) -> Void)?
    var shellHistory: ((Int, String, NSRange) -> ShellEditorEdit?)?
    var lastShellEdit: UUID?
    var shellSuggestion: ((String) -> String?)?
    private var suggestedSuffix: String?
    private var dismissedSuggestionPrefix: String?
    private lazy var ghost: UIButton = {
        let button = UIButton(type: .custom)
        button.contentHorizontalAlignment = .left
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.accessibilityIdentifier = "shellHistorySuggestion"
        button.accessibilityHint = "Inserts the suggested history text without running it"
        button.addTarget(self, action: #selector(acceptAutosuggestion), for: .touchUpInside)
        button.isHidden = true
        addSubview(button)
        return button
    }()
    var suggestionsVisible = false
    var moveSuggestion: ((Int) -> Void)?
    var completeSuggestion: (() -> Void)?
    var dismissSuggestions: (() -> Void)?
    var lastFocusRequest: UUID?
    var pendingInitialFocus = false
    var focusApplied: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPendingFocus()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        refreshAutosuggestion()
    }
    func refreshAutosuggestion() {
        if let dismissedSuggestionPrefix, dismissedSuggestionPrefix != text { self.dismissedSuggestionPrefix = nil }
        guard let shellSuggestion, isFirstResponder, window != nil, isEditable,
              !suggestionsVisible, markedTextRange == nil, selectedRange.length == 0,
              selectedRange.location == text.utf16.count, text != dismissedSuggestionPrefix,
              let suffix = shellSuggestion(text), !suffix.isEmpty,
              baseWritingDirection(for: endOfDocument, in: .backward) != .rightToLeft else {
            hideGhost(); return
        }
        let caret = caretRect(for: endOfDocument)
        let width = bounds.maxX - textContainerInset.right - textContainer.lineFragmentPadding - caret.maxX - 1
        // Keep the editor's layout and scroll extent determined by actual input.
        guard width >= 16, caret.maxY > bounds.minY, caret.minY < bounds.maxY else {
            hideGhost(); return
        }
        suggestedSuffix = suffix
        ghost.titleLabel?.font = font
        ghost.setTitleColor((textColor ?? .label).withAlphaComponent(0.42), for: .normal)
        ghost.setTitle(suffix, for: .normal)
        ghost.accessibilityLabel = "History suggestion: " + suffix
        ghost.frame = CGRect(x: caret.maxX + 1, y: caret.minY, width: width, height: caret.height)
        ghost.isAccessibilityElement = true; ghost.accessibilityElementsHidden = false; ghost.isEnabled = true
        ghost.isHidden = false
    }
    @objc private func acceptAutosuggestion() { insertSuggestion(word: false) }
    @objc private func acceptSuggestionWord() { insertSuggestion(word: true) }
    private func insertSuggestion(word: Bool) {
        refreshAutosuggestion()
        guard let suffix = suggestedSuffix else { return }
        let addition = word ? ShellHistorySuggestion.nextWord(prefix: text, suffix: suffix) : suffix
        guard !addition.isEmpty else { return }
        insertText(addition) // Native edit/undo; the suggestion itself never enters textStorage.
        dismissedSuggestionPrefix = word ? nil : text
        delegate?.textViewDidChange?(self)
        refreshAutosuggestion()
    }
    @objc private func dismissAutosuggestion() {
        dismissedSuggestionPrefix = text; hideGhost()
    }
    private func hideGhost() {
        suggestedSuffix = nil
        ghost.isHidden = true; ghost.isEnabled = false
        ghost.isAccessibilityElement = false; ghost.accessibilityElementsHidden = true
        ghost.accessibilityLabel = nil; ghost.setTitle(nil, for: .normal)
    }
    func applyPendingFocus() {
        guard pendingInitialFocus, window != nil else { return }
        // Run after SwiftUI finishes mounting the editor and dismissing the sheet.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.allowsRequestedFocus, self.pendingInitialFocus, self.window != nil else { return }
            self.pendingInitialFocus = false
            if self.becomeFirstResponder() { self.focusApplied?() }
        }
    }
    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(sendFromKeyboard))
        send.wantsPriorityOverSystemBehavior = true
        let newline = UIKeyCommand(input: "\r", modifierFlags: [.shift], action: #selector(insertNewline))
        newline.wantsPriorityOverSystemBehavior = true
        var shortcuts = [send, newline]
        if interruptCommand != nil {
            for input in ["c", "с"] {
                let interrupt = UIKeyCommand(input: input, modifierFlags: .control, action: #selector(interruptFromKeyboard))
                interrupt.wantsPriorityOverSystemBehavior = true; shortcuts.append(interrupt)
            }
        }
        if sendToAgent != nil {
            let agent = UIKeyCommand(input: "\r", modifierFlags: [.command], action: #selector(sendAgentFromKeyboard))
            agent.wantsPriorityOverSystemBehavior = true; shortcuts.append(agent)
        }
        if suggestionsVisible {
            for (input, action) in [(UIKeyCommand.inputUpArrow, #selector(previousSuggestion)), (UIKeyCommand.inputDownArrow, #selector(nextSuggestion)), ("\t", #selector(completeCurrentSuggestion)), (UIKeyCommand.inputEscape, #selector(hideSuggestions))] {
                let key = UIKeyCommand(input: input, modifierFlags: [], action: action)
                key.wantsPriorityOverSystemBehavior = true; shortcuts.append(key)
            }
        } else if shellHistory != nil || shellCompletion != nil {
            for (input, action) in [(UIKeyCommand.inputUpArrow, #selector(historyPrevious)), (UIKeyCommand.inputDownArrow, #selector(historyNext)), ("\t", #selector(shellComplete))] {
                let key = UIKeyCommand(input: input, modifierFlags: [], action: action)
                key.wantsPriorityOverSystemBehavior = true; shortcuts.append(key)
            }
        }
        if suggestionsVisible && shellCompletion != nil {
            let previous = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(previousSuggestion))
            previous.wantsPriorityOverSystemBehavior = true; shortcuts.append(previous)
        }
        if suggestedSuffix != nil {
            for (input, modifiers, action) in [
                (UIKeyCommand.inputRightArrow, UIKeyModifierFlags(), #selector(acceptAutosuggestion)),
                (UIKeyCommand.inputRightArrow, .alternate, #selector(acceptSuggestionWord)),
                (UIKeyCommand.inputEscape, UIKeyModifierFlags(), #selector(dismissAutosuggestion))
            ] {
                let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
                command.wantsPriorityOverSystemBehavior = true; shortcuts.append(command)
            }
        }
        return shortcuts + (super.keyCommands ?? [])
    }
    @objc private func sendAgentFromKeyboard() { if markedTextRange == nil { sendToAgent?() } }
    @objc private func interruptFromKeyboard() { interruptCommand?() }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let interruptCommand, presses.contains(where: { $0.key?.keyCode == .keyboardC && $0.key?.modifierFlags.contains(.control) == true }) {
            interruptCommand(); return
        }
        let remaining = Set(presses.filter { press in
            guard let key = press.key, suggestedSuffix != nil else { return true }
            let flags = key.modifierFlags.intersection([.command, .alternate, .control, .shift])
            if key.keyCode == .keyboardRightArrow && (flags.isEmpty || flags == .alternate) {
                insertSuggestion(word: flags == .alternate); return false
            }
            if key.keyCode == .keyboardEscape && flags.isEmpty { dismissAutosuggestion(); return false }
            return true
        })
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }
    @objc private func previousSuggestion() { if markedTextRange == nil { moveSuggestion?(-1) } }
    @objc private func nextSuggestion() { if markedTextRange == nil { moveSuggestion?(1) } }
    @objc private func completeCurrentSuggestion() { if markedTextRange == nil { completeSuggestion?() } }
    @objc private func hideSuggestions() { dismissSuggestions?() }
    @objc private func shellComplete() { if markedTextRange == nil { dismissAutosuggestion(); shellCompletion?(text, selectedRange) } }
    @objc private func historyPrevious() { moveHistory(-1) }
    @objc private func historyNext() { moveHistory(1) }
    private func moveHistory(_ direction: Int) {
        guard markedTextRange == nil else { return }
        // Preserve ordinary vertical caret movement in multiline/wrapped input.
        guard selectedRange.length == 0, let selectedTextRange else { return }
        let edge = direction < 0 ? beginningOfDocument : endOfDocument
        let caret = caretRect(for: selectedTextRange.start), boundary = caretRect(for: edge)
        if abs(caret.midY - boundary.midY) > 2 {
            if let position = position(from: selectedTextRange.start, in: direction < 0 ? .up : .down, offset: 1) {
                self.selectedTextRange = textRange(from: position, to: position)
            }
            return
        }
        if let edit = shellHistory?(direction, text, selectedRange) {
            dismissedSuggestionPrefix = edit.text
            text = edit.text; self.selectedRange = NSRange(location: edit.cursor, length: 0)
            delegate?.textViewDidChange?(self)
        }
    }
    @objc private func sendFromKeyboard() {
        guard markedTextRange == nil else { return }
        if suggestionsVisible && shellCompletion != nil { completeSuggestion?(); return }
        if yieldFocusOnSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingInitialFocus = false
            resignFirstResponder()
        }
        sendPrompt?()
    }
    @objc private func insertNewline() { insertText("\n") }
}

struct ToolDiffView: View {
    let diffs: [JSON]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(diffs.enumerated()), id: \.offset) { _, hunk in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(hunk["path"].string).font(.headline).textSelection(.enabled)
                            if hunk["oldText"] != .null { code(hunk["oldText"].string, sign: "−", color: .red) }
                            code(hunk["newText"].string, sign: "+", color: .green)
                        }
                    }
                }.padding(20)
            }.navigationTitle("Changes").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(minWidth: 320, minHeight: 300)
    }
    private func code(_ text: String, sign: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(String(text.prefix(32000)).components(separatedBy: "\n").prefix(300).enumerated()), id: \.offset) { _, line in
                Text(sign + " " + line).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            if text.count > 32000 || text.components(separatedBy: "\n").count > 300 { Text("Preview truncated").font(.caption) }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.10)).foregroundStyle(color)
    }
}

struct ReadingScrollObserver: ViewModifier {
    let onScroll: () -> Void
    let onBottom: () -> Void
    @State private var atBottom = false
    @State private var userScrolling = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 32
                } action: { _, bottom in
                    atBottom = bottom
                    if bottom && userScrolling {
                        userScrolling = false
                        onBottom()
                    }
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting {
                        userScrolling = true
                        onScroll()
                    } else if phase == .idle && userScrolling && atBottom {
                        userScrolling = false
                        onBottom()
                    }
                }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
                if abs(value.translation.height) > 12 { onScroll() }
            })
        }
    }
}

private struct ModelPaletteView: View {
    @EnvironmentObject private var store: PocketStore
    @Environment(\.harnessTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var highlighted = 0
    @State private var failure: String?
    private struct Option: Identifiable {
        let provider: String
        let providerName: String
        let model: String
        let name: String
        var id: String { provider + "/" + model }
    }
    private var options: [Option] {
        store.catalog["groups"].array.flatMap { group in
            group["models"].array.map { model in
                Option(provider: group["id"].string, providerName: group["name"].string,
                       model: model["id"].string, name: model["name"].string)
            }
        }.filter { query.isEmpty || "\($0.name) \($0.id) \($0.providerName)".localizedCaseInsensitiveContains(query) }
    }
    private func move(_ delta: Int) {
        guard !options.isEmpty else { return }
        highlighted = min(options.count - 1, max(0, highlighted + delta))
    }
    private func choose(_ option: Option) {
        guard store.connected, !store.selectingModel else { return }
        failure = nil
        Task {
            await store.selectModel(provider: option.provider, model: option.model)
            if store.model["provider"].string == option.provider && store.model["model"].string == option.model && store.error == nil {
                dismiss()
            } else { failure = store.error ?? "Model selection was not confirmed. Try again." }
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(">").foregroundStyle(theme.accent)
                    PaletteSearchField(text: $query, ink: theme.ink,
                        move: move, apply: { if options.indices.contains(highlighted) { choose(options[highlighted]) } },
                        cancel: { dismiss() }).frame(height: 30)
                }.font(.system(size: 17, design: .monospaced)).padding(18)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                                Button { choose(option) } label: {
                                    HStack {
                                        Text(index == highlighted ? ">" : " ").foregroundStyle(theme.accent)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(option.name).fontWeight(.medium)
                                            Text(option.id).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if store.model["provider"].string == option.provider && store.model["model"].string == option.model {
                                            Image(systemName: "checkmark").foregroundStyle(theme.accent)
                                        }
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(index == highlighted ? theme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).id(option.id).disabled(store.selectingModel || !store.connected)
                            }
                            if options.isEmpty { Text("No matching models").foregroundStyle(.secondary).padding(30) }
                        }.padding(10).id(query)
                    }.onChange(of: highlighted) { _, index in if options.indices.contains(index) { proxy.scrollTo(options[index].id) } }
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange).padding(12) }
                HStack {
                    Text("↑ ↓ choose · Enter apply · Esc close").font(.caption)
                    Spacer()
                    if store.selectingModel { ProgressView().controlSize(.small) }
                    Text("\(options.count) models").font(.caption)
                }.foregroundStyle(.secondary).padding(16)
            }.fontDesign(.monospaced).background(theme.canvas).foregroundStyle(theme.ink)
                .navigationTitle("/model").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                } }
                .task { searchFocused = true }
                .onChange(of: query) { _, _ in highlighted = 0 }
        }.presentationDetents([.large])
    }
}

private struct PaletteSearchField: UIViewRepresentable {
    @Binding var text: String
    let ink: Color
    let move: (Int) -> Void
    let apply: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PaletteTextField {
        let view = PaletteTextField()
        view.placeholder = "Search models or providers…"
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        view.autocorrectionType = .no; view.autocapitalizationType = .none
        view.accessibilityIdentifier = "modelSearch"
        view.delegate = context.coordinator
        view.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        return view
    }
    func updateUIView(_ view: PaletteTextField, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.textColor = UIColor(ink); view.move = move; view.apply = apply; view.cancel = cancel
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }
        @objc func changed(_ sender: UITextField) { parent.text = sender.text ?? "" }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { parent.apply(); return false }
    }
}
private final class PaletteTextField: UITextField {
    var move: ((Int) -> Void)?
    var apply: (() -> Void)?
    var cancel: (() -> Void)?
    private var requestedFocus = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && !requestedFocus {
            requestedFocus = true
            DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() }
        }
    }
    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(up)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(down)),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(selectModel)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closePalette))
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands + (super.keyCommands ?? [])
    }
    @objc private func up() { move?(-1) }
    @objc private func down() { move?(1) }
    @objc private func selectModel() { if markedTextRange == nil { apply?() } }
    @objc private func closePalette() { cancel?() }
}

#if DEBUG
struct ApprovalKeyboardPreview: View {
    @StateObject private var store = PocketStore()
    @State private var decision = "No decision"
    private var item: Interaction { Interaction(raw: .object([
        "eventId": .string("preview-only"), "agentId": .string("preview-session"),
        "event": .string("approval/request"), "request": .object([
            "toolName": .string("bash"), "reason": .string("Read a diagnostic file outside the workspace."), "callId": .string("preview-call")])]), clientID: "preview-client") }
    var body: some View {
        VStack {
            InteractionView(item: item, decisionHandler: { decision = $0.string })
                .environmentObject(store).frame(maxWidth: 560)
            Text(decision).accessibilityIdentifier("previewDecision")
        }.padding(30).task { store.connected = true; store.interactions = [item, item, item] }
    }
}
#endif
