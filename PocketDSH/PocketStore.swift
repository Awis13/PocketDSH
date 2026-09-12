import Foundation
import Combine

@MainActor
final class PocketStore: ObservableObject {
    @Published var endpoint = UserDefaults.standard.string(forKey: "harness.endpoint") ?? "" { didSet { persistPane() } }
    @Published var nativeShellMode = false { didSet { persistPane() } }
    var onWorkspaceChange: (() -> Void)?
    private var primaryPane = false
    var workspaceDetached = false
    func detachPane() { workspaceDetached = true; primaryPane = false; onWorkspaceChange = nil; suspend() }
    struct SavedPane: Codable {
        var endpoint: String
        var selectedID: String?
        var shell: Bool
    }
    var savedPane: SavedPane { SavedPane(endpoint: endpoint, selectedID: selectedID, shell: nativeShellMode) }
    func restorePane(_ state: SavedPane) {
        endpoint = state.endpoint; selectedID = state.selectedID; nativeShellMode = state.shell
        drafts = UserDefaults.standard.dictionary(forKey: "harness.drafts." + endpoint) as? [String: String] ?? [:]
        draft = drafts[selectedID ?? ""] ?? ""
    }
    private func persistPane() {
        if primaryPane, let data = try? JSONEncoder().encode(savedPane) { UserDefaults.standard.set(data, forKey: "harness.primaryPane.v1") }
        onWorkspaceChange?()
    }
    @Published var connected = false
    @Published var connecting = false
    @Published var error: String?
    @Published var sessions: [HarnessSession] = []
    @Published var workspaces: [HarnessWorkspace] = []
    @Published var archived = Set<String>()
    @Published var readingMode = false
    var openDefaultTaskWhenConnected = false
    @Published var voiceRecording = false
    @Published var selectedID: String? { didSet {
        if selectedID != oldValue { nativeRequests = []; nativeProtocolNotices = []; nativeCompaction = nil; nativeSupportsCompaction = false; nativeCompactionPending = false; nativeQueue = []; nativeQueueOmitted = 0; nativeSupportsQueue = false; nativeDiff = nil; nativeSupportsDiff = false; nativeDiffLoading = false; nativeDiffTimeout?.cancel(); nativeDiffTimeout = nil; queueTextHandlers.removeAll() }
        persistPane()
    } }
    @Published var composerFocusRequest: UUID?
    private var newlyCreatedSession: String?
    func focusNewSessionComposer() {
        guard let id = newlyCreatedSession else { return }
        newlyCreatedSession = nil
        if selectedID == id { composerFocusRequest = UUID() }
    }
    @Published var nativeCompaction: NativeCompactionInfo?
    @Published var nativeCompactionPending = false
    @Published var nativeSupportsCompaction = false
    @Published var nativeQueue: [NativeQueueItem] = []
    @Published var nativeQueueOmitted = 0
    @Published var nativeSupportsQueue = false
    @Published var nativeDiff: NativeDiffInfo?
    @Published var nativeSupportsDiff = false
    @Published var nativeDiffLoading = false
    private var nativeDiffTimeout: Task<Void, Never>?
    var compactingContext: Bool { nativeCompactionPending || nativeCompaction?.isRunning == true }
    var canCompactContext: Bool { usesNativeHarness && nativeSupportsCompaction && connected && nativeReady && !running && !compactingContext && nativeSubmission == nil }
    var canControlQueue: Bool { usesNativeHarness && nativeSupportsQueue && connected && nativeReady }
    var canReviewDiff: Bool { usesNativeHarness && nativeSupportsDiff && connected && nativeReady }
    private func compactionKey(_ session: String) -> String { "harness.compaction." + endpoint + "|" + session }
    @Published var nativeRequests: [NativeRequestInfo] = []
    @Published var nativeProtocolNotices: [String] = []
    @Published var rows: [TranscriptRow] = []
    @Published var interactions: [Interaction] = []
    @Published var queues: [String: JSON] = [:]
    @Published var jobs: [String: [SessionJob]] = [:]
    @Published var catalog: JSON = .null
    @Published var model: JSON = .null
    @Published var hasMore = false
    @Published var loadingHistory = false
    @Published var submitting = false
    @Published var selectingModel = false
    @Published var draft = "" {
        didSet {
            if let id = selectedID {
                drafts[id] = draft
                let key = "harness.drafts." + endpoint
                var latest = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
                latest[id] = draft
                UserDefaults.standard.set(latest, forKey: key)
            }
        }
    }
    @Published var images: [OutgoingImage] = []
    @Published var preparingImages = false
    @Published var imageLimits = ImageLimits()
    private var imageDrafts: [String: [OutgoingImage]] = [:]
    private let imageDraftFile = URL.documentsDirectory.appending(path: "image-drafts.plist")
    private let imageCache = NSCache<NSString, NSData>()
    private var imageDraftKey: String { endpoint + "|" + (selectedID ?? "") }
    @Published var pendingText: String?
    private(set) var transcript = Transcript()
    private var assistantLive = AssistantLiveStream()
    private var api: HarnessAPI?
    private var native: NativeChatConnection?
    @Published var nativeShell: NativeClient?
    @Published private var shellContextDrafts: [String: [ShellContextAttachment]] = [:]
    @Published private var shellDiffDrafts: [String: [ShellDiffAttachment]] = [:]
    @Published private var shellBlockSelections: [String: String] = [:]
    var shellAttachments: [ShellContextAttachment] {
        get { shellContextDrafts[imageDraftKey] ?? savedShellAttachments(key: imageDraftKey) }
        set { saveShellAttachments(newValue, key: imageDraftKey) }
    }
    var shellDiffAttachments: [ShellDiffAttachment] {
        get { shellDiffDrafts[imageDraftKey] ?? savedShellDiffAttachments(key: imageDraftKey) }
        set { saveShellDiffAttachments(newValue, key: imageDraftKey) }
    }
    private func savedShellAttachments(key: String) -> [ShellContextAttachment] {
        guard let data = UserDefaults.standard.data(forKey: "harness.shellContext." + key),
              let saved = try? JSONDecoder().decode([ShellContextAttachment].self, from: data) else { return [] }
        return Array(saved.prefix(4))
    }
    private func saveShellAttachments(_ attachments: [ShellContextAttachment], key: String) {
        shellContextDrafts[key] = attachments
        if attachments.isEmpty { UserDefaults.standard.removeObject(forKey: "harness.shellContext." + key) }
        else if let data = try? JSONEncoder().encode(attachments) { UserDefaults.standard.set(data, forKey: "harness.shellContext." + key) }
    }
    private func savedShellDiffAttachments(key: String) -> [ShellDiffAttachment] {
        guard let data = UserDefaults.standard.data(forKey: "harness.shellDiff." + key),
              let saved = try? JSONDecoder().decode([ShellDiffAttachment].self, from: data) else { return [] }
        return Array(saved.prefix(4))
    }
    private func saveShellDiffAttachments(_ attachments: [ShellDiffAttachment], key: String) {
        shellDiffDrafts[key] = attachments
        if attachments.isEmpty { UserDefaults.standard.removeObject(forKey: "harness.shellDiff." + key) }
        else if let data = try? JSONEncoder().encode(attachments) { UserDefaults.standard.set(data, forKey: "harness.shellDiff." + key) }
    }
    @discardableResult func attachDiffAttachment(path: String, header: String, oldText: String, newText: String, base: String) -> Bool {
        guard shellDiffAttachments.count < 4 else {
            error = "Up to four diff hunks can be attached. Remove one before adding another."; return false
        }
        shellDiffAttachments.append(ShellDiffAttachment(path: path, header: header, oldText: oldText, newText: newText, base: base))
        return true
    }
    var shellSelectedBlockID: String? {
        get { shellBlockSelections[imageDraftKey] }
        set { shellBlockSelections[imageDraftKey] = newValue }
    }
    @discardableResult func attachShellBlock(_ block: NativeBlock) -> Bool {
        guard shellAttachments.count < 4 || shellAttachments.contains(where: { $0.blockID == block.id }) else {
            error = "Up to four terminal blocks can be attached. Remove one before adding another."; return false
        }
        shellAttachments.removeAll { $0.blockID == block.id }
        shellAttachments.append(ShellContextAttachment(block: block))
        return true
    }
    private var nativeTranscript = NativeTranscript()
    var nativeReady = false
    private var nativeSubmission: (id: String, text: String, session: String, draft: String, attachmentIDs: [String], diffAttachmentIDs: [String])?
    private var queueTextHandlers: [String: (String?) -> Void] = [:]
    private var nativeReconnect: Task<Void, Never>?
    private var nativeRetry = 0
    private struct SavedNativeRequest: Codable {
        var id: String
        var text: String
        var terminal: Bool
        var draft: String?
        var attachmentIDs: [String]?
        var diffAttachmentIDs: [String]?
    }
    private func nativeRequestKey(_ id: String) -> String { "harness.nativeRequest." + endpoint + "|" + id }
    var usesNativeHarness: Bool { endpoint.hasPrefix("ws://") || endpoint.hasPrefix("wss://") }
    var supportsFullAccess: Bool { !usesNativeHarness }
    private var socket: URLSessionWebSocketTask?
    private var connectionTask: Task<Void, Never>?
    private var generation = UUID()
    private var followID = ""
    private var clientID = ""
    private var drafts: [String: String] = [:]
    private var pendingRequest: (id: String, text: String, session: String, imageIDs: [UUID])?
    private var projectionStores: [String: SessionProjectionStore] = [:]
    /// The per-session command catalog (`commands/list`), epoch-guarded by the
    /// ported CommandDirectory. Created on first use and never replaced, so a
    /// pull always has somewhere to publish and a strong-wait can never be
    /// stranded on a missing directory.
    private lazy var commandDirectory = CommandDirectory(startPull: { [weak self] token in
        self?.startCommandPull(token)
    })
    /// The selected session's catalog snapshot as the composer palette renders
    /// it, plus the cache state behind it. The directory is not observable, so
    /// every publish and invalidation republishes these for SwiftUI.
    @Published private(set) var commandCatalog: [CommandDescriptor] = []
    @Published private(set) var commandCatalogState: CommandDirectory.State = .cold
    /// The catalog pulls this connection still has in flight, by pull token.
    /// A pull belongs to one connection, so `disconnect()` cancels every
    /// entry and no `commands/list` is issued for the dead context. A late
    /// outcome is dropped by the directory's identity guard as well: the
    /// cancellation is what stops the work, the guard is what keeps it from
    /// landing.
    private struct CommandPull {
        let generation: UUID
        let task: Task<Void, Never>
    }
    private var commandPulls: [CommandDirectory.CommandPullToken: CommandPull] = [:]
    var selected: HarnessSession? { sessions.first { $0.id == selectedID } }
    var running: Bool { (selected?.running ?? false) || compactingContext }
    var liveReasoning: TranscriptRow? {
        guard connected, running, let latest = rows.last(where: { $0.kind != .notice }),
              latest.kind == .reasoning, !latest.complete, !latest.text.isEmpty else { return nil }
        return latest
    }
    var visibleSessions: [HarnessSession] { sessions.filter { !archived.contains($0.id) && $0.raw["origin"].string != "subagent" }.sorted { $0.date > $1.date } }
    var currentInteractions: [Interaction] { interactions.filter { $0.sessionID == selectedID } }
    var currentQueue: [JSON] { queues[selectedID ?? ""]?.array ?? [] }
    var modelLabel: String { model["model"].string.isEmpty ? "Host model" : model["model"].string }

    init(restoringPrimary: Bool = true) {
        imageCache.totalCostLimit = 24 * 1024 * 1024
        if let data = try? Data(contentsOf: imageDraftFile), let saved = try? PropertyListDecoder().decode([String: [OutgoingImage]].self, from: data) { imageDrafts = saved }
        drafts = UserDefaults.standard.dictionary(forKey: "harness.drafts." + endpoint) as? [String: String] ?? [:]
        if restoringPrimary, let data = UserDefaults.standard.data(forKey: "harness.primaryPane.v1"),
           let state = try? JSONDecoder().decode(SavedPane.self, from: data) { restorePane(state) }
        primaryPane = restoringPrimary
        SavedConnections.remember(endpoint)
    }

    private func connectionDiagnostic(_ stage: String, error: Error? = nil) {
        #if DEBUG
        var data: [String: Any] = ["stage": stage, "time": Date().description, "connected": connected]
        if let error {
            let e = error as NSError
            data["domain"] = e.domain; data["code"] = e.code
            if case DecodingError.dataCorrupted(let context) = error { data["decode"] = context.debugDescription }
            if case DecodingError.typeMismatch(_, let context) = error { data["decode"] = context.debugDescription; data["path"] = context.codingPath.map(\.stringValue) }
            data["message"] = e.localizedDescription.replacingOccurrences(of: #"\?[^\s\"]+"#, with: "?redacted", options: .regularExpression)
        }
        if let bytes = try? JSONSerialization.data(withJSONObject: data) {
            try? bytes.write(to: URL.documentsDirectory.appending(path: "connection-diagnostic.json"), options: .atomic)
        }
        #endif
    }
    func connect(input: String? = nil) async {
        #if DEBUG
        if let replay = ProcessInfo.processInfo.environment["DSH_NATIVE_REPLAY"] { loadNativeReplay(replay); return }
        if ProcessInfo.processInfo.environment["DSH_DEMO"] == "1" { loadDemo(); return }
        #endif
        let requested = (input ?? endpoint).trimmingCharacters(in: .whitespacesAndNewlines)
        if requested.hasPrefix("ws://") || requested.hasPrefix("wss://") { await connectNative(requested); return }
        guard !requested.isEmpty else { return }
        disconnect()
        let attempt = generation
        connecting = true; error = nil
        connectionDiagnostic("connecting")
        do {
            let (base, token) = try HarnessAPI.parse(input ?? endpoint)
            let candidate = HarnessAPI(base: base)
            if let token { try await candidate.login(token: token) }
            let result = try await candidate.rpc("session/list", args: ["_request": .object([:])])
            let loadedCatalog = (try? await candidate.rpc("session/modelCatalog")) ?? .null
            guard attempt == generation else { return }
            if endpoint != base.absoluteString {
                TurnNotifications.shared.stop("Connection changed")
                images = []; imageCache.removeAllObjects()
                sessions = []; workspaces = []; archived = []; selectedID = nil; rows = []; draft = ""; drafts = UserDefaults.standard.dictionary(forKey: "harness.drafts." + base.absoluteString) as? [String: String] ?? [:]; pendingRequest = nil; pendingText = nil
            }
            connectionDiagnostic("session-list-loaded")
            api = candidate; endpoint = base.absoluteString
            SavedConnections.remember(endpoint)
            UserDefaults.standard.set(endpoint, forKey: "harness.endpoint")
            sessions = result["items"].array.map { HarnessSession(raw: $0) }
            catalog = loadedCatalog
            startCarrier()
        } catch { if attempt == generation { self.error = error.localizedDescription; connecting = false; connectionDiagnostic("connect-failed", error: error) } }
    }
    func disconnect() {
        nativeReconnect?.cancel(); nativeReconnect = nil
        // The generation is the connection's identity and rotating it is how
        // the teardown is announced to everything already in flight, so the
        // outgoing value has to be read first: the pulls below are keyed by
        // it, and after the rotation they would look like the new
        // connection's and be left running.
        let dead = generation
        generation = UUID(); connectionTask?.cancel(); connectionTask = nil
        nativeShell?.disconnect(); nativeShell = nil
        native?.disconnect(); native = nil; nativeRequests = []; nativeProtocolNotices = []; nativeCompaction = nil; nativeSupportsCompaction = false; nativeCompactionPending = false; nativeQueue = []; nativeQueueOmitted = 0; nativeSupportsQueue = false; nativeDiff = nil; nativeSupportsDiff = false; nativeDiffLoading = false; nativeDiffTimeout?.cancel(); nativeDiffTimeout = nil; nativeReady = false; nativeSubmission = nil; queueTextHandlers.removeAll(); api = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        connected = false; connecting = false; loadingHistory = false; interactions = []; clientID = ""
        // A catalog belongs to one Host connection: the next connection must
        // never serve a snapshot the previous one warmed, and a pull of the
        // dead connection must not go on flying. Cancelling is best effort
        // (an RPC already on the wire cannot be recalled), but it does stop
        // the pulls that have not issued their RPC yet: the cancel sets the
        // task's flag synchronously on the main actor and the pull re-checks
        // it before it touches the transport. The directory's identity guard
        // makes the outcome of an already-sent RPC harmless.
        for pull in commandPulls.values where pull.generation == dead { pull.task.cancel() }
        commandPulls.removeAll()
        commandDirectory.removeAll(); syncCommandCatalog()
    }
    func transcribeVoice(_ data: Data, endpoint: String) async throws -> String {
        guard connected, self.endpoint == endpoint, let api else { throw HarnessError(message: "Reconnect to DSH and retry transcription.") }
        return try await api.transcribeVoice(data)
    }
    func sendVoiceTranscript(_ text: String, endpoint: String, sessionID: String, requestID: String) async throws {
        guard connected, self.endpoint == endpoint, selectedID == sessionID, let api else { throw HarnessError(message: "Reconnect to the original task to send this voice message.") }
        guard !submitting, pendingRequest == nil || pendingRequest?.id == requestID else { throw HarnessError(message: "Check the previous unconfirmed message before sending another.") }
        pendingRequest = (id: requestID, text: text, session: sessionID, imageIDs: [])
        pendingText = text; submitting = true
        defer { submitting = false }
        do {
            _ = try await api.rpc("session/prompt", args: ["request": .object([
                "sessionId": .string(sessionID), "requestId": .string(requestID), "mode": .string("queue"),
                "clientTimeZone": .string(TimeZone.current.identifier),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])])
            ])])
            if self.endpoint == endpoint { self.error = nil }
            reconcilePending()
        } catch {
            self.error = "Voice message send not confirmed. Check the conversation before retrying."
            throw HarnessError(message: "Send not confirmed. Check the conversation, then retry if needed.")
        }
    }
    func checkBackgroundNotifications() {
        guard let api, connected, let id = selectedID else { return }
        TurnNotifications.shared.start(api: api, endpoint: endpoint, session: id, requestID: "diagnostic-" + UUID().uuidString, title: "Background connection check", diagnostic: true)
    }
    func suspend() { disconnect() }
    private func startCarrier() {
        guard let api else { return }
        let token = generation
        connectionTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<5 {
                guard !Task.isCancelled, self.generation == token else { return }
                do {
                    self.connecting = true; self.interactions = []; self.queues = [:]; self.jobs = [:]; self.projectionStores = [:]
                    let socket = api.socket(); self.socket = socket
                    try await self.open("$events", id: "$events")
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard self.generation == token else { return }
                        let data: Data
                        switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                        let frame = try JSON.decodeWire(data)
                        try await self.receive(frame)
                    }
                } catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.socket?.cancel(with: .goingAway, reason: nil)
                    self.connected = false; self.interactions = []
                    self.error = "Connection interrupted. " + error.localizedDescription
                    self.connectionDiagnostic("websocket-failed", error: error)
                    if attempt < 4 { try? await Task.sleep(nanoseconds: UInt64(min(8, 1 << attempt)) * 1_000_000_000) }
                }
            }
            self.connecting = false
        }
    }
    private func sendFrame(_ frame: JSON) async throws {
        guard let socket else { throw HarnessError(message: "Not connected") }
        try await socket.send(.string(String(decoding: JSONEncoder().encode(frame), as: UTF8.self)))
    }
    private func open(_ endpoint: String, id: String, args: [String: JSON] = [:]) async throws {
        try await sendFrame(.object(["type": .string("open"), "streamId": .string(id), "endpoint": .string(endpoint), "payload": .object(["args": .object(args)])]))
    }
    private func receive(_ frame: JSON) async throws {
        let id = frame["streamId"].string
        if frame["type"].string == "error" {
            if id == followID { loadingHistory = false; error = frame["error"]["message"].string; return }
            throw HarnessError(message: frame["error"]["message"].string)
        }
        guard frame["type"].string == "item" else { return }
        let value = frame["value"], type = value["type"].string
        if id == "$events" {
            if type == "ready" {
                clientID = value["clientId"].string; connected = true; connecting = false; error = nil
                connectionDiagnostic("websocket-connected")
                // The reference client synthesizes `connection/reset` locally when the
                // transport (re)connects (dsh-api-gateway client.js:1433), so every
                // cached catalog is suspect; the directory drops and prewarms them.
                commandDirectory.apply(.connectionReset)
                try await open("workspace/follow", id: "workspaces")
                try await open("session/control", id: "control")
                // Refresh the list after readiness; later event frames stay buffered in the socket.
                await refresh()
                // A selection restored before this connection has no warm entry yet.
                if let id = selectedID { commandDirectory.warm(id) }
                syncCommandCatalog()
                if selectedID != nil { try await followSelected() }
            } else if type == "waterfall" {
                let item = Interaction(raw: value, clientID: clientID)
                if item.isApproval || value["event"].string == "user-questions/request" {
                    interactions.removeAll { $0.id == item.id }; interactions.append(item)
                }
            } else if type == "cancel" { interactions.removeAll { $0.id == value["eventId"].string } }
            else if type == "emit" {
                let args = value["args"].array, event = value["event"].string
                if event == "api-session/status", args.count == 2 { updateSession(args[0].string, key: "running", value: args[1]) }
                if event == "api-session/activity", args.count == 2 { updateSession(args[0].string, key: "updatedAt", value: args[1]) }
                if event == "api-session/added", let raw = args.first {
                    sessions.removeAll { $0.id == raw["sessionId"].string }; sessions.append(HarnessSession(raw: raw))
                }
                if event == "api-session/error", args.count == 2, args[0].string == selectedID { error = args[1].string }
                // Catalog invalidation, wired one for one like the reference client
                // (dsh-client-ui-commands client.js:537-545); the mapping itself
                // lives in CommandCatalog.swift so the offline gates can pin it.
                if let catalogEvent = commandCatalogEvent(name: event, args: args) {
                    commandDirectory.apply(catalogEvent); syncCommandCatalog()
                }
            }
        } else if id == "workspaces" {
            if type == "baseline" { workspaces = value["value"]["items"].array.map { HarnessWorkspace(raw: $0) }; archived = Set(value["value"]["archivedSessionIds"].array.map(\.string)) }
            else { // Reopen a complete baseline after a registry delta; no guessed patch semantics.
                try await sendFrame(.object(["type": .string("cancel"), "streamId": .string("workspaces")]))
                try await open("workspace/follow", id: "workspaces")
            }
        } else if id == "control" {
            if type == "baseline" {
                queues = value["value"]["queues"].object
                foldBaselineJobs(value["value"], into: &jobs)
                for (sid, p) in value["value"]["projections"].object { applyProjection(sid, p: p, replacement: true) }
            } else if type == "jobs" {
                foldSessionJobs(value, into: &jobs)
            } else if type == "projection" {
                let sid = value["sessionId"].string, key = value["key"].string
                applyProjection(sid, key: key, value: value["value"], seq: value["seq"].int)
            } else {
                // Queue frames and unknown control types land here, like the reference client.
                queues[value["sessionId"].string] = value["items"]
            }
            reconcilePending()
        } else if id == followID {
            if type == "snapshot" {
                transcript.replace(value["records"].array, cursor: value["cursor"].int)
                assistantLive.baseline(value["assistantStream"])
                hasMore = value["hasMore"].bool; loadingHistory = false
                if let sid = selectedID { applyProjection(sid, p: value["projections"]) }
            } else if type == "assistant-stream" {
                guard assistantLive.receive(value["frame"]) else { try await followSelected(); return }
            } else if type == "event" {
                guard transcript.append(value["event"]) else { try await followSelected(); return }
            }
            rows = assistantLive.merged(with: transcript.rows); reconcilePending()
        }
    }
    /// Fold a baseline block into this session's store. A control baseline
    /// replaces the process state the Host lost, so rows beyond its cursor drop
    /// before the new values land; a history snapshot is a plain seed.
    private func applyProjection(_ sid: String, p: JSON, replacement: Bool = false) {
        let baseline = ProjectionBaseline(p)
        var store = projectionStores[sid] ?? SessionProjectionStore()
        let previous = store.rows
        if replacement { store.truncate(lastSeq: baseline.asOfSeq) }
        store.seed(baseline: baseline)
        projectionStores[sid] = store
        for (key, row) in store.rows where previous[key] != row { patchProjection(sid, key: key, value: row.value) }
        for key in previous.keys where store.rows[key] == nil { dropProjection(sid, key: key) }
    }
    /// Fold one finished projection frame. The store decides staleness: an
    /// equal or lower watermark changes nothing, and the raw container only
    /// ever sees frames the store admitted.
    private func applyProjection(_ sid: String, key: String, value: JSON, seq: Int) {
        var store = projectionStores[sid] ?? SessionProjectionStore()
        let applied = store.apply(key: key, value: value, seq: seq)
        projectionStores[sid] = store
        if applied { patchProjection(sid, key: key, value: value) }
    }
    /// Remove a key the store no longer carries, so the raw container cannot
    /// serve it stale after a baseline drop.
    private func dropProjection(_ sid: String, key: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sid }) else { return }
        var raw = sessions[i].raw.object, p = raw["projections"]?.object ?? [:], values = p["values"]?.object ?? [:]
        values.removeValue(forKey: key); p["values"] = .object(values); raw["projections"] = .object(p); sessions[i].raw = .object(raw)
    }
    private func patchProjection(_ sid: String, key: String, value: JSON) {
        if let i = sessions.firstIndex(where: { $0.id == sid }) {
            var raw = sessions[i].raw.object, p = raw["projections"]?.object ?? [:], values = p["values"]?.object ?? [:]
            values[key] = value; p["values"] = .object(values); raw["projections"] = .object(p); sessions[i].raw = .object(raw)
        }
        if sid == selectedID && key == ProjectionKey.imageLimits { imageLimits = ImageLimits(value) }
        if sid == selectedID && key == ProjectionKey.modelSelection { model = value["next"] == .null ? catalog["default"] : value["next"] }
    }
    private func updateSession(_ id: String, key: String, value: JSON) {
        if let i = sessions.firstIndex(where: { $0.id == id }) { var raw = sessions[i].raw.object; raw[key] = value; sessions[i].raw = .object(raw) }
    }
    func refresh() async {
        if let native { do { try await native.send(NativeCommand(op: "list")) } catch { self.error = error.localizedDescription }; return }
        guard let api else { return }
        do { sessions = try await api.rpc("session/list", args: ["_request": .object([:])])["items"].array.map { HarnessSession(raw: $0) } }
        catch { self.error = error.localizedDescription }
    }
    func select(_ id: String?) async {
        #if DEBUG
        if let replay = ProcessInfo.processInfo.environment["DSH_NATIVE_REPLAY"] { loadNativeReplay(replay); return }
        if ProcessInfo.processInfo.environment["DSH_DEMO"] == "1" { loadDemo(); selectedID = id; return }
        #endif
        if let old = selectedID { drafts[old] = draft }
        drafts = UserDefaults.standard.dictionary(forKey: "harness.drafts." + endpoint) as? [String: String] ?? drafts
        if let data = try? Data(contentsOf: imageDraftFile), let saved = try? PropertyListDecoder().decode([String: [OutgoingImage]].self, from: data) { imageDrafts = saved }
        readingMode = false
        selectedID = id; images = imageDrafts[imageDraftKey] ?? []; imageLimits = ImageLimits(); draft = drafts[id ?? ""] ?? ""; rows = []; transcript = Transcript(); assistantLive = AssistantLiveStream(); hasMore = false
        pendingText = pendingRequest?.session == id ? (pendingRequest?.text.isEmpty == true ? "Image" : pendingRequest?.text) : nil
        model = selected?.raw["projections"]["values"]["modelSelection"]["next"] ?? .null
        if model == .null { model = catalog["default"] }
        // The catalog belongs to the selected session: republish (or clear) it
        // before any early return, so a disconnected or native switch can never
        // leave the previous session's rows in the palette.
        if !usesNativeHarness, connected, let id { commandDirectory.warm(id) }
        syncCommandCatalog()
        guard connected else { return }
        if let native {
            nativeReady = false; nativeTranscript = NativeTranscript(); nativeRequests = []; nativeProtocolNotices = []; nativeCompaction = nil; nativeSupportsCompaction = false; nativeCompactionPending = false; nativeQueue = []; nativeQueueOmitted = 0; nativeSupportsQueue = false; nativeDiff = nil; nativeSupportsDiff = false; nativeDiffLoading = false; nativeDiffTimeout?.cancel(); nativeDiffTimeout = nil; interactions = []
            guard let id else { native.selectedID = nil; return }
            loadingHistory = true; native.selectedID = id
            do { try await native.send(NativeCommand(op: "open", session: id)) }
            catch { self.error = error.localizedDescription; loadingHistory = false }
            return
        }
        do { try await followSelected() } catch { self.error = error.localizedDescription; loadingHistory = false }
    }
    private func followSelected() async throws {
        if !followID.isEmpty { try await sendFrame(.object(["type": .string("cancel"), "streamId": .string(followID)])) }
        followID = UUID().uuidString
        guard let id = selectedID else { return }
        loadingHistory = true
        try await open("session/follow", id: followID, args: ["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(id)]), "maxMessages": .number(50), "assistantStream": .bool(true)])])
    }
    func loadOlder() async {
        guard let api, let id = selectedID, let beforeSeq = transcript.firstSeq, !loadingHistory else { return }
        loadingHistory = true; let stream = followID
        defer { if stream == followID { loadingHistory = false } }
        do {
            let page = try await api.rpc("session/page", args: ["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(id)]), "throughSeq": .number(Double(transcript.cursor)), "beforeSeq": .number(Double(beforeSeq)), "maxMessages": .number(50)])])
            guard stream == followID else { return }
            transcript.prepend(page["records"].array); rows = assistantLive.merged(with: transcript.rows); hasMore = page["hasMore"].bool
        } catch { if stream == followID { self.error = error.localizedDescription } }
    }

    // MARK: - Session command catalog

    /// The directory's pull seam. The ported directory drives its pulls
    /// synchronously, while the RPC cannot be, so the pull is handed to the
    /// main actor and its outcome published under the token the directory
    /// minted (`CommandDirectory.publish`).
    private nonisolated func startCommandPull(_ token: CommandDirectory.CommandPullToken) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let pull = CommandPull(generation: self.generation, task: Task { @MainActor [weak self] in
                await self?.pullCommandCatalog(token)
            })
            self.commandPulls[token] = pull
        }
    }

    /// Issue one catalog pull for one session. A subagent session has no
    /// catalog of its own, so the reference short-circuits it to an empty list
    /// instead of calling `commands/list`. Every pull ends in a publish or an
    /// explicit abandon: a silently dropped outcome would leave the key pending
    /// and strand a strong-wait.
    private func pullCommandCatalog(_ token: CommandDirectory.CommandPullToken) async {
        let sessionId = token.sessionId
        let attempt = generation
        func publish(_ outcome: Result<[CommandDescriptor], Error>) {
            // Both arms republish the directory's current state: a pull whose
            // connection died abandons its token, but the published catalog
            // and its state must still match the directory afterwards - the
            // abandon may have dropped a pending entry the palette is showing.
            if attempt == generation {
                commandDirectory.publish(token, outcome)
            } else {
                commandDirectory.abandon(token,
                                         reason: HarnessError(message: "the connection was reset before the command catalog arrived"))
            }
            syncCommandCatalog()
        }
        /// Every exit drops the task handle; the pull is over, whatever it
        /// published. The handle must stay cancellable exactly as long as the
        /// RPC can still fly, so it is dropped here and not by the caller.
        func finish() {
            commandPulls.removeValue(forKey: token)
        }
        // One connection, one context: after a disconnect the socket, the api
        // and the selection of this pull are gone, so issuing the RPC would
        // address a dead connection. The guard is synchronous, so a cancel
        // that lands while the task is queued is observed here as well.
        guard !Task.isCancelled else { finish(); return }
        guard !usesNativeHarness else { finish(); publish(.success([])); return }
        switch commandCatalogRequest(sessionId: sessionId, origin: sessions.first { $0.id == sessionId }?.raw["origin"].string ?? "") {
        case .emptyCatalog:
            finish()
            publish(.success([]))
        case .list(let agentId):
            guard connected, let api, attempt == generation, !Task.isCancelled else {
                finish()
                publish(.failure(HarnessError(message: "the DSH connection is not ready")))
                return
            }
            do {
                let commands = commandDescriptors(try await api.rpc("commands/list", args: commandListArguments(agentId: agentId)))
                finish()
                publish(.success(commands))
            } catch {
                finish()
                publish(.failure(error))
            }
        }
    }

    /// Republish the selected session's catalog snapshot for SwiftUI. The
    /// directory itself is not observable, so every publish and invalidation
    /// ends here.
    private func syncCommandCatalog() {
        commandCatalog = commandDirectory.snapshot(selectedID ?? "")
        commandCatalogState = commandDirectory.status(selectedID ?? "")
    }

    /// Whether one composer line is a command line at all: the Host's own
    /// parse, so the composer can route it to the catalog path before the
    /// catalog is consulted. A line that does not parse (no leading slash, an
    /// invalid name, a bare "/") stays an ordinary message, exactly like a
    /// reference `matchEnter` miss.
    func isCommandLine(_ line: String) -> Bool {
        guard !usesNativeHarness else { return false }
        return parseCommand(line.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    /// Execute one command line through the Host's registry
    /// (`commands/execute`), strong-waiting the session's catalog first. Every
    /// slash line that parses as a command takes this path, and the wait is the
    /// reference's `matchEnter` rule: a warmup failure reports a notice and
    /// sends nothing ("a warmup failure rejects", dsh-client-ui-commands
    /// client.js:699-711, 733), while a servable catalog that does not claim
    /// the line - an unknown name (:735) or trailing arguments on a command
    /// that declares no input line (:751) - hands it to the ordinary message
    /// path with its draft and attachments. Admission is the only immediate
    /// answer: the lifecycle (`command/run` / `command/done`) is durably
    /// logged and folds into the transcript, so a successful command is never
    /// echoed here. A refused or errored invocation that carried attachments
    /// leaves the draft and the attachments in place for correction, like the
    /// reference client.
    func executeCommand(_ line: String) async {
        guard !usesNativeHarness, connected, let api, let id = selectedID, !submitting else { return }
        let host = endpoint
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = parseCommand(text)?.name, !name.isEmpty else { return }
        submitting = true
        defer { submitting = false }
        let descriptors: [CommandDescriptor]
        do { descriptors = try await commandDirectory.ensureReadyAsync(id) }
        catch is CommandDirectory.CommandPullCancelled {
            // The connection changed under the wait and the catalog it was
            // warming is gone. Nothing is wrong and nothing may be sent: a
            // command for the old connection must not fall through to the
            // message path of the new one.
            return
        } catch {
            self.error = "Could not load the command catalog: " + commandErrorMessage(error)
            return
        }
        guard host == endpoint, selectedID == id else { return }
        // A servable catalog that does not claim the line leaves it to the
        // ordinary message path, draft and attachments included.
        let resolved = descriptors.first { $0.name == name }
        guard commandClaimsLine(text, descriptor: resolved), let descriptor = resolved else {
            submitting = false
            await submit()
            return
        }
        let attachments = images
        guard attachments.isEmpty || commandAdmitsAttachments(descriptor) else {
            error = "The /\(descriptor.name) command does not accept attachments. Remove them first."; return
        }
        var submitted: [JSON] = []
        for attachment in attachments {
            guard let wire = CommandSubmitAttachment(attachment.part).wire else {
                error = "An attachment cannot be submitted with /" + descriptor.name + "."; return
            }
            submitted.append(wire)
        }
        do {
            let value = try await api.rpc("commands/execute", args: commandExecuteArguments(agentId: id, line: text, submittedAttachments: submitted))
            guard host == endpoint, selectedID == id else { return }
            guard value != .null else { self.error = "Unknown or malformed command: " + text; return }
            let execution = CommandExecution(value)
            if !attachments.isEmpty, execution.result.isError {
                self.error = execution.result.text ?? ("/" + descriptor.name + " failed")
                return
            }
            error = nil
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
            let sent = Set(attachments.map(\.id))
            if !sent.isEmpty {
                imageDrafts[imageDraftKey] = imageDrafts[imageDraftKey]?.filter { !sent.contains($0.id) }
                images.removeAll { sent.contains($0.id) }
                saveImageDrafts()
            }
        } catch { if host == endpoint { self.error = error.localizedDescription } }
    }
    func createDefaultTask() async {
        // Omitting workspaceId uses the Harness server's working directory.
        await create(workspaceID: nil)
        focusNewSessionComposer()
    }
    func create(workspaceID: String?) async {
        if native != nil, connected {
            let id = UUID().uuidString
            await select(id); newlyCreatedSession = id
            return
        }
        guard let api, connected else { return }
        do {
            var request: [String: JSON] = ["sessionId": .string("session-" + UUID().uuidString.lowercased())]
            if let workspaceID { request["workspaceId"] = .string(workspaceID) }
            let value = try await api.rpc("session/create", args: ["request": .object(request)])
            await refresh(); await select(value["sessionId"].string)
            newlyCreatedSession = selectedID
        } catch { self.error = error.localizedDescription }
    }
    func submit(mode: String = "queue") async {
        if native != nil { await submitNative(mode: mode); return }
        guard let api, connected, let id = selectedID, !submitting else { return }
        guard !preparingImages, !selectingModel else { return }
        let sendingEndpoint = endpoint
        let sentDraft = draft
        let text = sentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        let sendingImages = images
        do { try imageLimits.validate(sendingImages) } catch { self.error = error.localizedDescription; return }
        // A timeout keeps the same identity and text for an explicit retry, never an automatic resend.
        let request = pendingRequest.flatMap { $0.session == id && $0.text == text && $0.imageIDs == sendingImages.map(\.id) ? $0 : nil } ?? (id: UUID().uuidString, text: text, session: id, imageIDs: sendingImages.map(\.id))
        pendingRequest = request; pendingText = text.isEmpty ? "Image" : text; submitting = true
        defer { submitting = false }
        do {
            _ = try await api.rpc("session/prompt", args: ["request": .object(["sessionId": .string(id), "requestId": .string(request.id), "mode": .string(mode), "clientTimeZone": .string(TimeZone.current.identifier), "content": .array((text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]) + sendingImages.map(\.part))])])
            guard endpoint == sendingEndpoint else { return }
            let sentIDs = Set(sendingImages.map(\.id)), key = sendingEndpoint + "|" + id
            imageDrafts[key] = imageDrafts[key]?.filter { !sentIDs.contains($0.id) }
            if selectedID == id { images.removeAll { sentIDs.contains($0.id) } }
            saveImageDrafts(key: key)
            if selectedID == id && draft == sentDraft { draft = "" }
            if drafts[id] == sentDraft { drafts[id] = "" }
            error = nil
            reconcilePending()
        } catch { self.error = "Send not confirmed: \(error.localizedDescription). Check the conversation before retrying." }
    }
    private func reconcilePending() {
        guard let p = pendingRequest else { return }
        let inHistory = selectedID == p.session && transcript.events.contains { $0["type"].string == "user/message" && $0["data"]["source"]["rpcId"].string == p.id }
        let inQueue = queues[p.session]?.array.contains { $0["rpcId"].string == p.id } ?? false
        if inHistory || inQueue { pendingRequest = nil; pendingText = nil }
    }
    func addImage(data: Data, name: String, sessionID: String, host: String) async {
        guard !usesNativeHarness else { error = "Image input is not yet supported by Native Harness. Your DSH connection still supports attachments."; return }
        guard sessionID == selectedID, host == endpoint, !submitting else { return }
        let limits = imageLimits
        do {
            let image = try await Task.detached(priority: .userInitiated) { try ImagePreparation.prepare(data, name: name, limits: limits) }.value
            guard !Task.isCancelled, sessionID == selectedID, host == endpoint, !submitting else { return }
            try imageLimits.validate(images + [image])
            let total = imageDrafts.values.flatMap { $0 }.reduce(0) { $0 + $1.data.count }
            guard total + image.data.count <= 32 * 1024 * 1024 else { throw HarnessError(message: "Image drafts have reached 32 MB. Remove or send some attachments.") }
            images.append(image); imageDrafts[imageDraftKey] = images; saveImageDrafts()
        } catch { if sessionID == selectedID && host == endpoint { self.error = error.localizedDescription } }
    }
    func removeImage(_ id: UUID) {
        guard !submitting else { return }
        images.removeAll { $0.id == id }; imageDrafts[imageDraftKey] = images; saveImageDrafts()
    }
    private func saveImageDrafts(key: String? = nil) {
        let changedKey = key ?? imageDraftKey
        let changed = imageDrafts[changedKey] ?? []
        if let data = try? Data(contentsOf: imageDraftFile), let saved = try? PropertyListDecoder().decode([String: [OutgoingImage]].self, from: data) { imageDrafts = saved }
        imageDrafts[changedKey] = changed
        imageDrafts = imageDrafts.filter { !$0.value.isEmpty }
        do { try PropertyListEncoder().encode(imageDrafts).write(to: imageDraftFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { self.error = "Could not save attachments: " + error.localizedDescription }
    }
    func attachmentData(_ attachmentID: String, sessionID: String) async throws -> Data {
        guard connected, let api else { throw HarnessError(message: "Connect to DSH to load this image") }
        let key = endpoint + "|" + sessionID + "|" + attachmentID
        if let data = imageCache.object(forKey: key as NSString) { return data as Data }
        let value = try await api.rpc("session/attachment", args: ["request": .object(["sessionId": .string(sessionID), "attachmentId": .string(attachmentID)])])
        guard let data = Data(base64Encoded: value["data"].string), !data.isEmpty, data.count <= 32 * 1024 * 1024 else { throw HarnessError(message: "DSH returned an invalid image") }
        imageCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }
    func compactContext(fromEditor: Bool = false) async {
        guard usesNativeHarness, nativeSupportsCompaction else {
            error = "This host does not support context compaction. Connect to an updated Native Harness host."; return
        }
        guard connected, nativeReady, let native, let session = selectedID else {
            error = "Reconnect to the native host before compacting context."; return
        }
        guard !running, !compactingContext, nativeSubmission == nil else {
            error = "Wait for the current operation to finish, or use Stop."; return
        }
        let operationID = UUID().uuidString
        UserDefaults.standard.set(operationID, forKey: compactionKey(session))
        nativeCompactionPending = true
        if fromEditor, NativeCompactionInfo.isEditorCommand(draft) { draft = "" }
        do {
            try await native.send(NativeCommand(op: "compact", session: session, id: operationID))
        } catch {
            if selectedID == session { nativeCompactionPending = false; self.error = "Compaction not confirmed. Reconnect to retrieve its status: " + error.localizedDescription }
        }
    }
    func reviewDiff(base: String) async {
        guard usesNativeHarness, nativeSupportsDiff else {
            error = "This host does not support workspace diffs. Connect to an updated Native Harness host."; return
        }
        guard connected, nativeReady, let native, let session = selectedID else {
            error = "Open a native session before reviewing changes."; return
        }
        guard NativeDiffInfo.isValidBase(base) else {
            error = "Enter a valid base: worktree, staged, HEAD or a branch name."; return
        }
        nativeDiffLoading = true
        nativeDiffTimeout?.cancel()
        nativeDiffTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled, self.nativeDiffLoading else { return }
            self.nativeDiffLoading = false
            self.error = "The host did not answer the diff request. Reconnect and try again."
        }
        do {
            try await native.send(NativeCommand(op: "diff", session: session, id: UUID().uuidString, base: base))
        } catch {
            nativeDiffTimeout?.cancel(); nativeDiffTimeout = nil
            nativeDiffLoading = false
            self.error = "Could not request the diff: " + error.localizedDescription
        }
    }
    func cancel() async {
        if let native, let id = selectedID {
            do { try await native.send(NativeCommand(op: "cancel", session: id)) } catch { self.error = error.localizedDescription }
            return
        }
        await command("session/cancel", request: ["sessionId": .string(selectedID ?? "")])
    }
    func editQueued(_ id: String, prompt: String) async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { error = "Enter the replacement request text."; return }
        await queueAction("edit", itemID: id, text: text)
    }
    func removeQueued(_ id: String) async { await queueAction("remove", itemID: id) }
    func steerQueued(_ id: String) async { await queueAction("steer", itemID: id) }
    /// Fetches the full stored prompt for one queued item on demand. The dock's
    /// list preview stays clipped, so editing a long request never needs retyping.
    func loadQueuedText(_ id: String, completion: @escaping (String?) -> Void) {
        guard canControlQueue, let native, let session = selectedID else { completion(nil); return }
        queueTextHandlers[id] = completion
        Task {
            do { try await native.send(NativeCommand(op: "queue", session: session, id: UUID().uuidString, action: "text", itemID: id)) }
            catch {
                queueTextHandlers.removeValue(forKey: id)?(nil)
                self.error = error.localizedDescription
            }
        }
    }
    private func queueAction(_ action: String, itemID: String, text: String? = nil) async {
        guard canControlQueue, let native, let session = selectedID else {
            error = "Reconnect to the native host before changing the queue."; return
        }
        do {
            try await native.send(NativeCommand(op: "queue", session: session, id: UUID().uuidString, text: text, action: action, itemID: itemID))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func selectModel(provider: String, model: String) async {
        if usesNativeHarness { error = "Native Harness currently uses the model configured on its host: " + modelLabel; return }
        guard let api, connected, let id = selectedID, !selectingModel else { return }
        let host = endpoint
        selectingModel = true
        defer { selectingModel = false }
        do {
            let value = try await api.rpc("session/selectModel", args: ["request": .object(["sessionId": .string(id), "provider": .string(provider), "model": .string(model)])])
            guard host == endpoint else { return }
            let accepted = value["selected"]
            if selectedID == id { self.model = accepted }
            // DSH also persists this selection as the default for unconfigured sessions.
            // Re-read it rather than continuing to display the catalog loaded at login.
            let updatedCatalog = try await api.rpc("session/modelCatalog")
            guard host == endpoint else { return }
            catalog = updatedCatalog
            await refresh()
            if selectedID == id { try await followSelected() }
            error = nil
        } catch { if host == endpoint { self.error = "Could not confirm the selected model: " + error.localizedDescription } }
    }
    private func command(_ name: String, request: [String: JSON]) async {
        guard connected, let api else { return }
        do { _ = try await api.rpc(name, args: ["request": .object(request)]) } catch { self.error = error.localizedDescription }
    }
    func enableFullAccess(for item: Interaction) async -> Bool {
        guard let api, connected, item.sessionID == selectedID, item.clientID == clientID,
              interactions.contains(where: { $0.id == item.id }) else { return false }
        do {
            let value = try await api.rpc("commands/execute", args: commandExecuteArguments(agentId: item.sessionID,
                line: "/permission danger-full-access", submittedAttachments: []))
            guard value["result"]["kind"].string == "success" else {
                throw HarnessError(message: value["result"]["text"].string.isEmpty ? "Full access was not confirmed by Harness." : value["result"]["text"].string)
            }
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func answer(_ item: Interaction, value: JSON) async {
        if let native {
            guard connected, item.sessionID == selectedID, interactions.contains(where: { $0.id == item.id }),
                  ["allowed-once", "rejected"].contains(value.string) else { return }
            do { try await native.send(NativeCommand(op: "approval", session: item.sessionID, id: item.id, allow: value.string == "allowed-once")) }
            catch { self.error = error.localizedDescription }
            return
        }
        guard let api, connected, item.clientID == clientID, interactions.contains(where: { $0.id == item.id }) else { return }
        do {
            _ = try await api.rpc("$events/result", args: ["clientId": .string(clientID), "eventId": .string(item.id), "outcome": .object(["kind": .string("result"), "value": value])])
            interactions.removeAll { $0.id == item.id }
        } catch { self.error = error.localizedDescription }
    }
}

// Native events feed the existing session list, transcript and approval UI.
extension PocketStore {
    private func connectNative(_ input: String) async {
        let previousEndpoint = endpoint
        disconnect(); connecting = true; error = nil
        do {
            let (url, suppliedToken) = try NativeChatConnection.parse(input)
            let key = "native:" + url.absoluteString
            let token = suppliedToken ?? SecureConnection.read(key) ?? ""
            guard token.utf8.count >= 32 else { throw HarnessError(message: "Paste the Native Harness connection URL containing its host token.") }
            if let suppliedToken { try SecureConnection.write(suppliedToken, key: key) }
            if previousEndpoint != url.absoluteString {
                selectedID = nil; sessions = []; rows = []; images = []; draft = ""
                drafts = UserDefaults.standard.dictionary(forKey: "harness.drafts." + url.absoluteString) as? [String: String] ?? [:]
            }
            endpoint = url.absoluteString; workspaces = []; archived = []; queues = [:]
            pendingRequest = nil; pendingText = nil
            UserDefaults.standard.set(endpoint, forKey: "harness.endpoint")
            let connection = NativeChatConnection(); native = connection
            connection.onEvent = { [weak self] event in self?.receiveNative(event) }
            connection.onFailure = { [weak self] message in
                self?.connected = false; self?.connecting = false; self?.loadingHistory = false
                self?.nativeReady = false; self?.nativeSubmission = nil; self?.interactions = []; self?.error = message
                guard let self, !self.workspaceDetached else { return }
                self.nativeRetry = min(4, self.nativeRetry + 1)
                let delay = min(10, 1 << (self.nativeRetry - 1))
                self.nativeReconnect = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    await self.connect()
                }
            }
            connection.connect(url: url, token: token)
        } catch { connecting = false; self.error = error.localizedDescription }
    }
    private func nativeSession(_ info: NativeSessionInfo) -> HarnessSession {
        HarnessSession(raw: .object(["sessionId": .string(info.id), "cwd": .string(info.workspace),
            "running": .bool(info.running), "updatedAt": .number(info.updatedAt * 1000),
            "projections": .object(["values": .object(["title": .string(info.title)])])]))
    }
    private func receiveNative(_ event: NativeEvent) {
        if event.op == "sessions" {
            let wasConnecting = connecting
            sessions = (event.sessions ?? []).map(nativeSession)
            model = .object(["provider": .string("native"), "model": .string(event.model ?? "Host model")])
            catalog = .object(["default": model, "groups": .array([])])
            connected = true; connecting = false; nativeRetry = 0
            SavedConnections.remember(endpoint)
            if wasConnecting, let id = selectedID {
                if sessions.contains(where: { $0.id == id }) { Task { await self.select(id) } }
                else { selectedID = nil; rows = []; interactions = []; nativeReady = false; error = "The saved session is not in this host's journal. Check the host address and storage path." }
            }
            return
        }
        // `accepted` applies regardless of the current selection so switching
        // sessions mid-send cannot strand a submission; `error`/`queueRejected`
        // and the transcript events below stay scoped to the selected session.
        guard event.deliversToSelection(selectedID) else { return }
        if event.op == "error" { error = event.text ?? "Native Harness error"; nativeSubmission = nil; loadingHistory = false; return }
        if event.op == "accepted", let submission = nativeSubmission, submission.id == event.id {
            if selectedID == submission.session, draft.trimmingCharacters(in: .whitespacesAndNewlines) == submission.draft { draft = "" }
            let contextKey = endpoint + "|" + submission.session
            let remaining = (shellContextDrafts[contextKey] ?? savedShellAttachments(key: contextKey)).filter { !submission.attachmentIDs.contains($0.id) }
            saveShellAttachments(remaining, key: contextKey)
            let remainingDiffs = (shellDiffDrafts[contextKey] ?? savedShellDiffAttachments(key: contextKey)).filter { !submission.diffAttachmentIDs.contains($0.id) }
            saveShellDiffAttachments(remainingDiffs, key: contextKey)
            let key = "harness.drafts." + endpoint
            var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            if saved[submission.session]?.trimmingCharacters(in: .whitespacesAndNewlines) == submission.draft {
                saved[submission.session] = ""; drafts[submission.session] = ""
                UserDefaults.standard.set(saved, forKey: key)
            }
            pendingRequest = nil; pendingText = nil; nativeSubmission = nil
            UserDefaults.standard.removeObject(forKey: nativeRequestKey(submission.session))
        }
        if event.op == "completion" { nativeShell?.receive(event); return }
        if event.op == "queueRejected" {
            // Clear the pending full-text fetch for this item (if any) before
            // surfacing the failure so the editor never keeps spinning.
            queueTextHandlers.removeValue(forKey: event.id ?? "")?(nil)
            error = NativeQueueInfo.rejectionDetail(event.text ?? ""); return
        }
        if event.op == "queueText", let itemID = event.id, let text = event.text {
            queueTextHandlers.removeValue(forKey: itemID)?(text)
            return
        }
        if event.op == "opened", let id = event.session {
            if nativeShell?.id != id {
                let shell = NativeClient(id: id, endpoint: endpoint, token: "")
                shell.externalSend = { [weak self] command in
                    guard let self, self.selectedID == command.session, let connection = self.native else { return }
                    Task { do { try await connection.send(command) } catch { self.error = error.localizedDescription } }
                }
                nativeShell = shell
            }
            nativeReady = false; interactions = []
            if !sessions.contains(where: { $0.id == id }) {
                sessions.append(nativeSession(NativeSessionInfo(id: id, title: "New task", workspace: event.workspace ?? "", model: event.model ?? "", running: false, updatedAt: Date().timeIntervalSince1970)))
            }
            model = .object(["provider": .string("native"), "model": .string(event.model ?? "Host model")])
            if event.gap == true { error = "Native host retained only part of this conversation. Earlier output is unavailable in this view." }
        }
        if event.op == "synced" { nativeReady = true; loadingHistory = false; focusNewSessionComposer() }
        if ["opened", "synced", "pty", "blockStart", "blockEnd", "ptyExit", "shellReset", "terminalSize"].contains(event.op) { nativeShell?.receive(event) }
        if event.op == "workspaceAction" || event.op == "pty" { return }
        nativeTranscript.apply(event)
        nativeSupportsCompaction = nativeTranscript.supportsCompaction
        nativeSupportsQueue = nativeTranscript.supportsQueue
        nativeSupportsDiff = nativeTranscript.supportsDiff
        if nativeCompaction != nativeTranscript.compaction { nativeCompaction = nativeTranscript.compaction }
        if nativeQueue != nativeTranscript.queue { nativeQueue = nativeTranscript.queue }
        if nativeQueueOmitted != nativeTranscript.queueOmitted { nativeQueueOmitted = nativeTranscript.queueOmitted }
        if nativeDiff != nativeTranscript.diff { nativeDiff = nativeTranscript.diff }
        if event.op == "diff" { nativeDiffLoading = false; nativeDiffTimeout?.cancel(); nativeDiffTimeout = nil }
        // A queue snapshot retires the optimistic echo only once the host has
        // admitted the exact request, matching the DSH reconciliation.
        if let pending = pendingRequest, nativeQueue.contains(where: { $0.id == pending.id }) {
            pendingRequest = nil; pendingText = nil
        }
        if let session = selectedID {
            let key = compactionKey(session)
            let pending = UserDefaults.standard.string(forKey: key)
            if let receipt = event.compaction, receipt.id == pending {
                nativeCompactionPending = false
                if receipt.isFinished { UserDefaults.standard.removeObject(forKey: key) }
            }
            if event.op == "compactionRejected" {
                if event.id == pending { UserDefaults.standard.removeObject(forKey: key); nativeCompactionPending = false }
                error = NativeCompactionInfo(id: event.id ?? "rejected", state: "failed", code: event.text).detail
            }
            // Reconcile only. Reconnecting must never start inference by itself.
            if event.op == "synced", let pending, nativeSupportsCompaction {
                nativeCompactionPending = true
                Task { try? await native?.send(NativeCommand(op: "compactStatus", session: session, id: pending)) }
            }
        }
        if nativeRequests != nativeTranscript.requests { nativeRequests = nativeTranscript.requests }
        if nativeProtocolNotices != nativeTranscript.protocolNotices { nativeProtocolNotices = nativeTranscript.protocolNotices }
        if ["blockStart", "blockEnd", "ptyExit"].contains(event.op), let block = nativeShell?.blocks.last {
            nativeTranscript.updateShell(block)
        }
        if (nativeReady || event.op == "opened"), rows != nativeTranscript.rows { rows = nativeTranscript.rows }
        if event.op == "user", let id = selectedID {
            if nativeReady {
                updateSession(id, key: "updatedAt", value: .number(Date().timeIntervalSince1970 * 1000))
                if selected?.title == "New task" { patchProjection(id, key: ProjectionKey.title, value: .string(String((event.text ?? "").prefix(70)))) }
            }
            if pendingRequest?.id == event.id { pendingRequest = nil; pendingText = nil }
            if let data = UserDefaults.standard.data(forKey: nativeRequestKey(id)),
               let saved = try? JSONDecoder().decode(SavedNativeRequest.self, from: data), saved.id == event.id {
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == (saved.draft ?? saved.text) { draft = "" }
                shellAttachments.removeAll { (saved.attachmentIDs ?? []).contains($0.id) }
                shellDiffAttachments.removeAll { (saved.diffAttachmentIDs ?? []).contains($0.id) }
                UserDefaults.standard.removeObject(forKey: nativeRequestKey(id)); nativeSubmission = nil
            }
        }
        if event.op == "stage", NativeRequestInfo.knownStages.contains(event.stage ?? ""), let id = selectedID {
            let ended = ["completed", "cancelled", "failed", "interrupted"].contains(event.stage ?? "")
            updateSession(id, key: "running", value: .bool(!ended))
            if ended { interactions = [] }
        }
        if event.op == "status", let id = selectedID {
            updateSession(id, key: "running", value: .bool(event.running ?? false))
            if event.running == false { interactions = [] }
            if let code = event.text, code != "CANCELLED", code != event.compaction?.code {
                error = code == "CONTEXT_LIMIT" ? "Model context limit exceeded. Terminal and history are preserved; start a new session or attach less output." : "Native Harness: " + code
            } else if error?.hasPrefix("Native Harness:") == true { error = nil }
        }
        if event.op == "approval", let approval = event.approval, let id = selectedID {
            interactions.removeAll { $0.id == approval.id }
            interactions.append(Interaction(raw: .object(["eventId": .string(approval.id), "agentId": .string(id),
                "event": .string("approval/request"), "request": .object(["toolName": .string(approval.name),
                    "reason": .string("Workspace: " + approval.workspace + "\n" + approval.arguments)])]), clientID: "native"))
        }
        if event.op == "approvalAnswered" { interactions.removeAll { $0.id == event.id } }
    }
    func askFromShell(_ text: String, block: NativeBlock?) async {
        guard nativeReady, native != nil else { return }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || block != nil || !shellAttachments.isEmpty || !shellDiffAttachments.isEmpty else { error = "Enter a question or choose a command block to discuss."; return }
        guard !submitting, nativeSubmission == nil else { return }
        guard draft.isEmpty || draft.trimmingCharacters(in: .whitespacesAndNewlines) == question else {
            error = "There is an unsent draft. Send or clear it before asking about another block."; return
        }
        if let block, !attachShellBlock(block) { return }
        draft = question.isEmpty ? "Explain this terminal output." : question
        nativeShell?.shellDraft = ""
        await submitNative(withTerminal: true)
    }
    private func submitNative(withTerminal: Bool = false, mode: String = "queue") async {
        guard let native, connected, nativeReady, let id = selectedID, !submitting, nativeSubmission == nil else { return }
        guard images.isEmpty else { error = "Native Harness image input is not yet supported."; return }
        let submittedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedDraft.isEmpty else { return }
        let attachments = shellAttachments
        let diffs = shellDiffAttachments
        let text = ShellPromptContent(question: submittedDraft, attachments: attachments, diffs: diffs).text
        let saved = UserDefaults.standard.data(forKey: nativeRequestKey(id)).flatMap { try? JSONDecoder().decode(SavedNativeRequest.self, from: $0) }
        let matching = saved.flatMap { $0.text == text ? $0 : nil }
        let request = pendingRequest.flatMap { $0.session == id && $0.text == text ? $0 : nil }
            ?? matching.map { (id: $0.id, text: text, session: id, imageIDs: [UUID]()) }
            ?? (id: UUID().uuidString, text: text, session: id, imageIDs: [UUID]())
        // Explicit attachments replace the implicit live terminal tail. What the user previews
        // is the terminal context sent with this request, including on retry.
        let terminal = matching?.terminal ?? (withTerminal && attachments.isEmpty && diffs.isEmpty)
        let attachmentIDs = attachments.map(\.id)
        let diffAttachmentIDs = diffs.map(\.id)
        if let data = try? JSONEncoder().encode(SavedNativeRequest(id: request.id, text: text, terminal: terminal, draft: submittedDraft, attachmentIDs: attachmentIDs, diffAttachmentIDs: diffAttachmentIDs)) { UserDefaults.standard.set(data, forKey: nativeRequestKey(id)) }
        pendingRequest = request; pendingText = submittedDraft; submitting = true
        nativeSubmission = (request.id, text, id, submittedDraft, attachmentIDs, diffAttachmentIDs)
        defer { submitting = false }
        do {
            try await native.send(NativeCommand(op: "prompt", session: id, id: request.id, text: text, withTerminal: terminal, mode: mode))
            error = nil
        } catch { nativeSubmission = nil; self.error = "Send not confirmed. Reconnect and check the conversation before retrying: " + error.localizedDescription }
    }
}
