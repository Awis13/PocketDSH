import SwiftUI
import UIKit

struct HarnessView: View {
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
    private let commands = [("/view", "Switch chat / terminal"), ("/model", "Search models"), ("/new", "New task in default workspace")]
    private var commandMatches: [(String, String)] {
        guard !commandsDismissed, store.draft.hasPrefix("/"), !store.draft.contains(where: { $0.isWhitespace }) else { return [] }
        return commands.filter { $0.0.hasPrefix(store.draft.lowercased()) }
    }
    private func runCommand(_ command: String) {
        guard !creatingTask else { return }
        switch command {
        case "/view": store.draft = ""; terminalInput.toggle(); store.composerFocusRequest = UUID()
        case "/model": store.draft = ""; modelPalette = true
        case "/new":
            guard store.connected else { return }
            store.draft = ""; creatingTask = true
            Task { await store.createDefaultTask(); creatingTask = false }
        default: return
        }
    }
    private func moveCommand(_ delta: Int) {
        guard !commandMatches.isEmpty else { return }
        commandIndex = (commandIndex + delta + commandMatches.count) % commandMatches.count
    }
    private func completeCommand() {
        guard !commandMatches.isEmpty else { return }
        store.draft = commandMatches[min(commandIndex, commandMatches.count - 1)].0
    }
    @AppStorage("harness.terminalInput") private var terminalInput = false
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
            runCommand(commandMatches[min(commandIndex, commandMatches.count - 1)].0); return
        }
        let command = store.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if commands.contains(where: { $0.0 == command }) { runCommand(command); return }
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
                        if store.running {
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
            if terminalInput {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(theme.accent)
                    Text(store.selected?.cwd ?? "~").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("DSH").foregroundStyle(theme.accent)
                }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            if !commandMatches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(commandMatches.enumerated()), id: \.element.0) { index, command in
                        Button { runCommand(command.0) } label: {
                            HStack(spacing: 12) {
                                Text(index == commandIndex ? "❯" : " ").foregroundStyle(theme.accent)
                                Text(command.0).frame(width: 68, alignment: .leading)
                                Text(command.1).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }.font(.system(size: 13, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 8)
                                .background(index == commandIndex ? theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).disabled(creatingTask).accessibilityIdentifier("command" + command.0)
                    }
                    Text("↑↓ choose · Tab complete · Enter run · Esc dismiss").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4)
                }.fontDesign(.monospaced).padding(6).background(theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: 540, alignment: .leading)
            }
            if creatingTask { ProgressView("Creating task…").font(.caption) }
            ImageComposer()
            if !desktopComposer { VoiceComposer() }
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
                }.disabled(!store.connected || store.selectingModel)
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
                if desktopComposer { VoiceComposer(compact: true).fixedSize(horizontal: true, vertical: false) }
                Button {
                    sendPrompt()
                } label: { Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold)).frame(width: 38, height: 38).background(theme.accent, in: Circle()).foregroundStyle(theme.canvas) }
                    .disabled(!canSend)
                    .opacity(store.draft.isEmpty && store.images.isEmpty ? 0.3 : 1).accessibilityLabel("Send").accessibilityIdentifier("sendPrompt")
                    .contextMenu { if store.running { Button("Steer current turn") { Task { await store.submit(mode: "steer") } } } }
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
            DesktopPromptEditor(text: $store.draft, focusRequest: $store.composerFocusRequest, collapsed: store.readingMode, ink: theme.ink, monospaced: terminalInput, textSize: theme.messageSize, textShadow: theme.glassSettings.shadow, suggestionsVisible: !commandMatches.isEmpty, moveSuggestion: moveCommand, completeSuggestion: completeCommand, dismissSuggestions: { commandsDismissed = true }, send: sendPrompt)
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
            }.padding(13).harnessSurface(radius: 21) }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if !row.text.isEmpty { AssistantMarkdown(text: row.text) }
                ForEach(Array(row.images.enumerated()), id: \.offset) { _, ref in RemoteAttachment(reference: ref, sessionID: sessionID) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .reasoning:
            DisclosureGroup { Text(row.text).font(.system(size: 15, design: terminal ? .monospaced : theme.design)).foregroundStyle(.secondary).textSelection(.enabled) } label: { Label(row.complete ? "Reasoning" : "Thinking…", systemImage: "sparkle").font(.caption).foregroundStyle(.secondary) }
        case .tool:
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup {
                    ScrollView(.horizontal) { Text(row.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(.top, 8) }.frame(maxHeight: 250)
                } label: {
                    HStack(spacing: 9) { Image(systemName: row.failed ? "exclamationmark.circle" : row.complete ? "checkmark.circle" : "terminal"); Text(row.text).font(.system(size: 13, design: .monospaced)).lineLimit(1) }.foregroundStyle(row.failed ? .orange : .secondary)
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
        case .notice: Label(row.text, systemImage: "info.circle").font(.caption).foregroundStyle(row.failed ? .orange : .secondary)
        }
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
                        Button("Full access…") { confirmFullAccess = true }
                    }
                }
                if activePane { Text("⌘↵ Allow once · ⌘⌫ Reject · ⌘⇧A Full access").font(.caption2).foregroundStyle(.secondary) }
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
                Button("") { confirmFullAccess = true }.keyboardShortcut("a", modifiers: [.command, .shift]).hidden().disabled(busy || !store.connected)
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
            Button("Full access…") { confirmFullAccess = true }.buttonStyle(.borderless)
        }
    }
    private func answer(_ value: JSON) { guard !busy, store.connected else { return }; if let decisionHandler { decisionHandler(value); return }; busy = true; Task { await store.answer(item, value: value); busy = false } }
}

private struct ConversationContentHeight: PreferenceKey {
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
    let send: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> DesktopPromptTextView {
        let view = DesktopPromptTextView()
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 16)
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "composer"
        view.accessibilityLabel = "Give your agent a task"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: DesktopPromptTextView, context: Context) {
        context.coordinator.parent = self
        view.sendPrompt = send
        view.suggestionsVisible = suggestionsVisible
        view.moveSuggestion = moveSuggestion
        view.completeSuggestion = completeSuggestion
        view.dismissSuggestions = dismissSuggestions
        if collapsed && view.isFirstResponder { view.resignFirstResponder() }
        let font: UIFont = monospaced ? .monospacedSystemFont(ofSize: textSize, weight: .regular) : .systemFont(ofSize: textSize)
        if view.font != font { view.font = font }
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = Float(textShadow)
        view.layer.shadowRadius = textShadow > 0 ? 2 : 0
        view.layer.shadowOffset = CGSize(width: 0, height: 1)
        view.textColor = UIColor(ink)
        if view.text != text { view.text = text }
        if let focusRequest, view.lastFocusRequest != focusRequest {
            view.focusApplied = { if self.focusRequest == focusRequest { self.focusRequest = nil } }
            view.lastFocusRequest = focusRequest
            view.pendingInitialFocus = true
            view.applyPendingFocus()
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DesktopPromptTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(120, max(40, measured.height)))
    }
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: DesktopPromptEditor
        init(_ parent: DesktopPromptEditor) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.activatePane() }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}
final class DesktopPromptTextView: UITextView {
    var sendPrompt: (() -> Void)?
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
    func applyPendingFocus() {
        guard pendingInitialFocus, window != nil else { return }
        // Run after SwiftUI finishes mounting the editor and dismissing the sheet.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingInitialFocus, self.window != nil else { return }
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
        if suggestionsVisible {
            for (input, action) in [(UIKeyCommand.inputUpArrow, #selector(previousSuggestion)), (UIKeyCommand.inputDownArrow, #selector(nextSuggestion)), ("\t", #selector(completeCurrentSuggestion)), (UIKeyCommand.inputEscape, #selector(hideSuggestions))] {
                let key = UIKeyCommand(input: input, modifierFlags: [], action: action)
                key.wantsPriorityOverSystemBehavior = true; shortcuts.append(key)
            }
        }
        return shortcuts + (super.keyCommands ?? [])
    }
    @objc private func previousSuggestion() { if markedTextRange == nil { moveSuggestion?(-1) } }
    @objc private func nextSuggestion() { if markedTextRange == nil { moveSuggestion?(1) } }
    @objc private func completeCurrentSuggestion() { if markedTextRange == nil { completeSuggestion?() } }
    @objc private func hideSuggestions() { dismissSuggestions?() }
    @objc private func sendFromKeyboard() {
        guard markedTextRange == nil else { return }
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

private struct ReadingScrollObserver: ViewModifier {
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
