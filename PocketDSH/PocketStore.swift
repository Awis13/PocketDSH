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
        if selectedID != oldValue { nativeRequests = []; nativeProtocolNotices = []; nativeCompaction = nil; nativeSupportsCompaction = false; nativeCompactionPending = false; nativeQueue = []; nativeQueueOmitted = 0; nativeSupportsQueue = false; nativeDiff = nil; nativeSupportsDiff = false; nativeDiffLoading = false; nativeDiffTimeout?.cancel(); nativeDiffTimeout = nil; queueTextHandlers.removeAll(); clearAccessConfirmation() }
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
            if let id = selectedID { draftTable.write(draft, for: id); persistDrafts() }
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
    /// The session-selection epoch: rotates on every session switch and on
    /// disconnect, so a deferred selectModel response cannot revive an old
    /// session's request just because the session id matches again.
    private var selectionEpoch = UUID()
    /// The Remote carrier's stream identity: which socket attempt is live,
    /// which IDs its streams carry, and which ping/refresh work may still
    /// report. The socket and the UI stay here; every "whose frame is this"
    /// decision lives in the coordinator, which the offline gates compile.
    private let carrier = RemoteStreamConnection()
    /// The async model-selection path with operation ownership: who owns the
    /// busy flag, and which deferred response may still land.
    private let selection = ModelSelectionGate()
    private var clientID = ""
    /// The composer's draft lines and their versions (`ComposerDrafts`). The
    /// version is what tells a pending send whether the line it carried is
    /// still there; the text alone cannot.
    private var draftTable = ComposerDrafts()
    /// The saved lines, as the rest of the store reads and reloads them. A
    /// bulk reload replaces the lines and keeps the versions: both describe the
    /// same composer.
    private var drafts: [String: String] {
        get { draftTable.lines }
        set { draftTable.lines = newValue }
    }
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
    /// The catalog pulls of this connection. The table lives in
    /// `CommandPullConnection` (CommandCatalog.swift) because PocketStore is
    /// in no gate-compilable target: the connection-scoped bookkeeping - a
    /// pull registered before its task can run, work of a dead generation
    /// recognised before the transport, the teardown cancelling exactly the
    /// pulls of the connection that is closing - is checkable there. A late
    /// outcome is dropped by the directory's identity guard as well: the
    /// cancellation is what stops the work, the guard is what keeps it from
    /// landing.
    private lazy var commandConnection = CommandPullConnection(directory: commandDirectory)
    /// The unanswered full-access confirmation, or nil when there is none. It is
    /// the one question both escalation routes ask - the composer's command line
    /// and the approval card's button - so it is published once and rendered
    /// once: two surfaces cannot stack two alerts over one switch. The lifecycle
    /// behind it (one pending action, its frozen identity, exactly one dispatch
    /// per answer) is `FullAccessGate` (FullAccessConfirmation.swift), which the
    /// offline checks drive.
    @Published private(set) var accessConfirmation: FullAccessGate.Pending?
    /// Whether a confirmed approval is being escalated and answered right now:
    /// the card stays disabled until the Host has taken the decision.
    @Published private(set) var fullAccessExecuting = false
    private lazy var fullAccessGate = FullAccessGate()
    /// The seam the carrier's failure and ready edges drop the pending
    /// confirmation through, so the invalidation the carrier triggers is the
    /// same production logic the offline integration checks drive.
    private lazy var confirmationLifecycle = ConfirmationLifecycle(fullAccessGate)
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
    var modelLabel: String {
        let base = model["model"].string.isEmpty ? "Host model" : model["model"].string
        if let effort = effectiveEffortLabel(selection: model, catalog: catalog) { return base + " · " + effort }
        return base
    }

    init(restoringPrimary: Bool = true) {
        imageCache.totalCostLimit = 24 * 1024 * 1024
        if let data = try? Data(contentsOf: imageDraftFile), let saved = try? PropertyListDecoder().decode([String: [OutgoingImage]].self, from: data) { imageDrafts = saved }
        drafts = UserDefaults.standard.dictionary(forKey: "harness.drafts." + endpoint) as? [String: String] ?? [:]
        if restoringPrimary, let data = UserDefaults.standard.data(forKey: "harness.primaryPane.v1"),
           let state = try? JSONDecoder().decode(SavedPane.self, from: data) { restorePane(state) }
        primaryPane = restoringPrimary
        SavedConnections.remember(endpoint)
    }

    /// Record one connection event. The record is built by
    /// `RemoteStreamDiagnostic`, which admits only app-produced values (stage,
    /// close code, attempt, stream kind) and redacts messages, so nothing that
    /// can carry a credential reaches the file. The history is bounded at 80
    /// records; the single-record file stays as it was.
    private func connectionDiagnostic(_ stage: String, error: Error? = nil, details: [String: Any] = [:]) {
        #if DEBUG
        let record = RemoteStreamDiagnostic(stage: stage, connected: connected, details: details, error: error).record
        if let bytes = try? JSONSerialization.data(withJSONObject: record) {
            let directory = URL.documentsDirectory
            try? bytes.write(to: directory.appending(path: "connection-diagnostic.json"), options: .atomic)
            let historyURL = directory.appending(path: "connection-events.json")
            let history = ((try? Data(contentsOf: historyURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? []
            let bounded = RemoteStreamDiagnostic.appending(record, to: history)
            if let log = try? JSONSerialization.data(withJSONObject: bounded) { try? log.write(to: historyURL, options: .atomic) }
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
        generation = UUID(); selectionEpoch = UUID(); connectionTask?.cancel(); connectionTask = nil
        // The carrier's streams, its ping and its scheduled refreshes die with
        // the connection: after this no late frame, ping or list may report.
        carrier.stop()
        nativeShell?.disconnect(); nativeShell = nil
        native?.disconnect(); native = nil; nativeRequests = []; nativeProtocolNotices = []; nativeCompaction = nil; nativeSupportsCompaction = false; nativeCompactionPending = false; nativeQueue = []; nativeQueueOmitted = 0; nativeSupportsQueue = false; nativeDiff = nil; nativeSupportsDiff = false; nativeDiffLoading = false; nativeDiffTimeout?.cancel(); nativeDiffTimeout = nil; nativeReady = false; nativeSubmission = nil; queueTextHandlers.removeAll(); api = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        connected = false; connecting = false; loadingHistory = false; interactions = []; clientID = ""
        // A catalog belongs to one Host connection: the next connection must
        // never serve a snapshot the previous one warmed, and a pull of the
        // dead connection must not go on flying. Cancelling is best effort
        // (an RPC already on the wire cannot be recalled), but it does stop
        // the pulls that have not issued their RPC yet: every pull of this
        // connection is in the table before its task can run, so the stop
        // below reaches them all, and their bodies re-check the identity this
        // generation rotation invalidates before touching the transport. The
        // directory's identity guard makes the outcome of an already-sent
        // RPC harmless.
        commandConnection.stop()
        commandDirectory.removeAll(); syncCommandCatalog()
        clearAccessConfirmation()
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
            await self.carrier.run { attempt in
                try await self.carrierAttempt(attempt, api: api, generation: token)
            } onAttempt: { _ in
                // Every attempt is a clean slate: nothing a previous socket
                // folded may answer for this one.
                self.connecting = true; self.interactions = []; self.queues = [:]; self.jobs = [:]; self.projectionStores = [:]
            } onFailure: { attempt, error in
                // The actual close code is read before the socket is dropped;
                // 1008 is a refused stream request, while a terminated carrier
                // (the gateway's missed heartbeats) has no close code of its own
                // and must not be reported as one.
                let closeCode = self.socket?.closeCode.rawValue ?? 0
                self.socket?.cancel(with: .goingAway, reason: nil)
                self.socket = nil
                self.connected = false; self.interactions = []
                // The escalation question names the connection it was asked on;
                // a failed carrier is gone and a carrier that comes back is a new
                // one (a new client id and a re-warmed catalog), so the unanswered
                // question is dropped on a carrier failure as well as on a teardown
                // - a reopened socket must not resurrect an action the user has not
                // answered.
                self.confirmationLifecycle.carrierFailed(); self.accessConfirmation = nil
                self.error = "Connection interrupted. " + error.localizedDescription
                self.connectionDiagnostic("websocket-failed", error: error, details: ["closeCode": closeCode, "attempt": attempt.index])
            } onFinish: { [weak self] in
                // Only the carrier whose connection is still the current one
                // reports its end: a superseded carrier must not clear the
                // state of the connection that replaced it.
                guard let self, self.generation == token else { return }
                self.connecting = false
            }
        }
    }
    /// One carrier attempt: open the event stream on a fresh socket and read it
    /// until it fails. The ping belongs to this attempt and never reconnects
    /// anything; the loop that called this body is the only retry owner.
    private func carrierAttempt(_ attempt: RemoteStreamConnection.Attempt, api: HarnessAPI, generation token: UUID) async throws {
        let socket = api.socket()
        self.socket = socket
        // The ping's callbacks are weakly held: the job is owned by the
        // coordinator, which the store owns, and a closure that captured the
        // store strongly would keep it alive for as long as a ping hangs.
        carrier.startPing(ping: { try await socket.ping() }, onFailure: { [weak self] attempt, error in
            self?.connectionDiagnostic("ping-failed", error: error, details: ["attempt": attempt.index])
        })
        try await carrier.subscribe(.events, endpoint: "$events", on: socket)
        while !Task.isCancelled {
            let message = try await socket.receive()
            guard self.generation == token, carrier.isCurrent(attempt) else { throw CancellationError() }
            let data: Data
            switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
            let frame = try JSON.decodeWire(data)
            try await receive(frame, on: socket)
        }
    }
    private func receive(_ frame: JSON, on socket: URLSessionWebSocketTask) async throws {
        // The identity check comes first, so a late frame, error or end of a
        // replaced stream - of a previous selection or a previous socket - is
        // discarded before it can touch any state.
        guard let delivery = carrier.admit(frame) else { return }
        switch delivery.frame["type"].string {
        case "error":
            let failure = HarnessError(message: delivery.frame["error"]["message"].string)
            if delivery.kind == .conversation {
                loadingHistory = false; error = failure.localizedDescription
                connectionDiagnostic("conversation-failed", error: failure, details: ["stream": delivery.kind.rawValue])
                return
            }
            connectionDiagnostic("stream-failed", error: failure, details: ["stream": delivery.kind.rawValue])
            throw failure
        case "end":
            // A stream this client holds open was finished by the server: the
            // ID is retired and the reader reconnects. Only that loop may
            // reopen it, so the end is never papered over with stale state.
            carrier.end(delivery.kind)
            if delivery.kind == .conversation { loadingHistory = false }
            connectionDiagnostic("stream-ended", details: ["stream": delivery.kind.rawValue])
            throw RemoteStreamConnection.StreamEnded(kind: delivery.kind)
        case "item":
            break
        default:
            return
        }
        let value = delivery.frame["value"], type = value["type"].string
        if delivery.kind == .events {
            if type == "ready" {
                let attempt = carrier.attempt
                clientID = value["clientId"].string; connected = true; connecting = false; error = nil
                connectionDiagnostic("websocket-connected", details: ["attempt": attempt?.index ?? 0])
                // A ready frame is a fresh carrier connection, with its own
                // client id: an escalation question asked on the previous one is
                // no longer answerable, so it is dropped before anything can be
                // dispatched against the new stream.
                confirmationLifecycle.attemptReady(); accessConfirmation = nil
                // The reference client synthesizes `connection/reset` locally when the
                // transport (re)connects (dsh-api-gateway client.js:1433), so every
                // cached catalog is suspect; the directory drops and prewarms them.
                commandDirectory.apply(.connectionReset)
                try await carrier.subscribe(.workspaces, endpoint: "workspace/follow", on: socket)
                guard carrier.isCurrent(attempt) else { return }
                try await carrier.subscribe(.control, endpoint: "session/control", on: socket)
                // A selection restored before this connection has no warm entry yet.
                if let id = selectedID { commandDirectory.warm(id) }
                syncCommandCatalog()
                if selectedID != nil { try await followSelected() }
                // The HTTP list refresh runs outside this loop: awaiting it here
                // would stop reading the socket, and its result is applied only
                // while this attempt is still the live one.
                carrier.scheduleRefresh { [weak self] token in await self?.refresh(token: token) }
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
        } else if delivery.kind == .workspaces {
            if type == "baseline" { workspaces = value["value"]["items"].array.map { HarnessWorkspace(raw: $0) }; archived = Set(value["value"]["archivedSessionIds"].array.map(\.string)) }
            else { // Reopen a complete baseline after a registry delta; no guessed patch semantics.
                try await carrier.subscribe(.workspaces, endpoint: "workspace/follow", on: socket)
            }
        } else if delivery.kind == .control {
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
        } else if delivery.kind == .conversation {
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
    /// Refresh the session list. `token` is the refresh's own identity when the
    /// carrier scheduled it for one socket attempt; a caller that passes none
    /// (the list buttons, a create, a model change) is bound to the attempt
    /// live at this moment. Either way a result - success or failure - is
    /// applied only while that identity is still the live one, so a list that
    /// arrives after a reconnect belongs to the connection that asked for it.
    func refresh(token: RemoteStreamConnection.RefreshToken? = nil) async {
        if let native { do { try await native.send(NativeCommand(op: "list")) } catch { self.error = error.localizedDescription }; return }
        guard let api else { return }
        let connection = generation
        let refresh = token ?? carrier.currentRefreshToken()
        do {
            let result = try await api.rpc("session/list", args: ["_request": .object([:])])
            guard generation == connection, carrier.accepts(refresh) else { return }
            sessions = result["items"].array.map { HarnessSession(raw: $0) }
        } catch {
            guard generation == connection, carrier.accepts(refresh) else { return }
            self.error = error.localizedDescription
        }
    }
    func select(_ id: String?) async {
        #if DEBUG
        if let replay = ProcessInfo.processInfo.environment["DSH_NATIVE_REPLAY"] { loadNativeReplay(replay); return }
        if ProcessInfo.processInfo.environment["DSH_DEMO"] == "1" { loadDemo(); selectedID = id; return }
        #endif
        // Rotate the epoch only on a real session switch: reselecting the
        // current session keeps its in-flight selection live, while A -> B -> A
        // still invalidates the original request - its epoch is gone even
        // though the session id matches again.
        if selectedID != id { selectionEpoch = UUID() }
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
    /// Point the conversation stream at the selected session. The previous ID
    /// is retired before the first suspension, so frames of the session the
    /// user just left - its snapshot, its events, its errors - are discarded
    /// from the moment the switch is decided. A deselect retires the stream
    /// without opening another one.
    private func followSelected() async throws {
        guard let socket else {
            // No socket to tell: the ID is still retired, so nothing can
            // arrive for it later.
            try await carrier.cancel(.conversation, on: nil)
            return
        }
        guard let id = selectedID else {
            loadingHistory = false
            try await carrier.cancel(.conversation, on: socket)
            return
        }
        loadingHistory = true
        try await carrier.subscribe(.conversation, endpoint: "session/follow", args: ["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(id)]), "maxMessages": .number(50), "assistantStream": .bool(true)])], on: socket)
    }
    func loadOlder() async {
        guard let api, let id = selectedID, let beforeSeq = transcript.firstSeq, !loadingHistory else { return }
        // The history page belongs to the conversation stream it was started
        // for: a page that lands after a switch, a deselect or a reconnect is
        // dropped instead of being prepended to another session's transcript.
        guard let page = carrier.beginPage() else { return }
        loadingHistory = true
        // This flag describes exactly this page's wait, and only one page can
        // be in flight, so the page that is still the newest one ends it - even
        // when its own stream was replaced meanwhile (a reconnect that
        // re-followed a fresh stream): no other code path would ever clear it,
        // because the page's snapshot can no longer arrive.
        defer { if carrier.isNewest(page) { loadingHistory = false } }
        do {
            let result = try await api.rpc("session/page", args: ["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(id)]), "throughSeq": .number(Double(transcript.cursor)), "beforeSeq": .number(Double(beforeSeq)), "maxMessages": .number(50)])])
            guard carrier.owns(page) else { return }
            transcript.prepend(result["records"].array); rows = assistantLive.merged(with: transcript.rows); hasMore = result["hasMore"].bool
        } catch { if carrier.owns(page) { self.error = error.localizedDescription } }
    }

    // MARK: - Session command catalog

    /// The directory's pull seam. The ported directory drives its pulls
    /// synchronously, while the RPC cannot be, so the pull is handed to the
    /// main actor and its outcome published under the token the directory
    /// minted (`CommandDirectory.publish`).
    private func startCommandPull(_ token: CommandDirectory.CommandPullToken) {
        commandConnection.bind(token) { [weak self] in
            await self?.pullCommandCatalog(token)
        }
    }

    /// Issue one catalog pull for one session. A subagent session has no
    /// catalog of its own, so the reference short-circuits it to an empty list
    /// instead of calling `commands/list`. Every pull ends in a publish or an
    /// explicit abandon: a silently dropped outcome would leave the key pending
    /// and strand a strong-wait.
    private func pullCommandCatalog(_ token: CommandDirectory.CommandPullToken) async {
        let sessionId = token.sessionId
        let attempt = commandDirectory.catalogGeneration
        func publish(_ outcome: Result<[CommandDescriptor], Error>) {
            // Both arms republish the directory's current state: a pull whose
            // connection died abandons its token, but the published catalog
            // and its state must still match the directory afterwards - the
            // abandon may have dropped a pending entry the palette is showing.
            if attempt == commandDirectory.catalogGeneration {
                commandDirectory.publish(token, outcome)
            } else {
                commandDirectory.abandon(token,
                                         reason: HarnessError(message: "the connection was reset before the command catalog arrived"))
            }
            syncCommandCatalog()
        }
        // One connection, one context: the socket, the api and the selection
        // of this pull belong to the generation it was started in. The guards
        // below are synchronous with respect to that generation (the main
        // actor never interleaves them with a teardown), and the last one is
        // re-checked after the RPC so a cancelled pull can never install its
        // outcome on the next connection's directory. The task handle belongs
        // to `commandConnection`, which drops it on every exit.
        guard !commandConnection.isStale(token), !Task.isCancelled else { return }
        guard !usesNativeHarness else { publish(.success([])); return }
        switch commandCatalogRequest(sessionId: sessionId, origin: sessions.first { $0.id == sessionId }?.raw["origin"].string ?? "") {
        case .emptyCatalog:
            publish(.success([]))
        case .list(let agentId):
            guard connected, let api, !commandConnection.isStale(token), !Task.isCancelled else {
                publish(.failure(HarnessError(message: "the DSH connection is not ready")))
                return
            }
            do {
                let commands = commandDescriptors(try await api.rpc("commands/list", args: commandListArguments(agentId: agentId)))
                publish(.success(commands))
            } catch {
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

    /// Freeze the composer for one send action. Main-actor synchronous by
    /// design: the caller IS the action - the send button, the keyboard
    /// shortcut, a palette row - so this states what the user sent before that
    /// action suspends for the first time. Nil when there is nothing to freeze:
    /// a native session (its own queue path is unchanged) or no connection and
    /// session to address.
    func composerSubmission() -> ComposerSubmission? {
        guard !usesNativeHarness, connected, let id = selectedID else { return nil }
        return ComposerSubmission(draft: draft, images: images, sessionID: id, endpoint: endpoint, catalogGeneration: commandDirectory.catalogGeneration, draftVersion: draftTable.version(of: id))
    }

    /// The draft map as it is persisted for the connected Host - the copy
    /// `select` reloads the session table from.
    private var savedDrafts: [String: String] {
        UserDefaults.standard.dictionary(forKey: "harness.drafts." + endpoint) as? [String: String] ?? [:]
    }

    /// Persist the draft lines for the connected Host - the copy `select`
    /// reloads the session table from, so a line a send forgot stays forgotten.
    private func persistDrafts() {
        UserDefaults.standard.set(draftTable.lines, forKey: "harness.drafts." + endpoint)
    }

    /// One successful send's effect on the composer's drafts, applied in the
    /// order that makes it correct: `ComposerDrafts.applySent` decides before it
    /// writes, and the live line it returns is assigned by the caller only
    /// after its own identity guard. Returns the line the live composer must
    /// take, or nil when this send does not own it.
    private func applySentDraftCleanup(_ sent: ComposerSubmission) -> String? {
        guard endpoint == sent.endpoint else { return nil }
        let outcome = draftTable.applySent(sent, liveSession: selectedID, liveDraft: draft)
        if outcome.forgotSavedLine { persistDrafts() }
        return outcome.liveDraft
    }

    /// Run one frozen composer action through the Host's registry
    /// (`commands/execute`), strong-waiting the session's catalog first.
    ///
    /// The snapshot is the only content this method sends. The wait below can
    /// take a whole round trip and the composer stays editable throughout, so
    /// the line, the attachments, the session and the connection are all read
    /// from the snapshot the user's action froze - never from the live composer
    /// again. Every step after a suspension re-checks that identity
    /// (`stillApplies`), so a reconnect or a session switch cancels the action
    /// instead of issuing its RPC against the next connection.
    ///
    /// The wait is the reference's `matchEnter` rule: a warmup failure reports
    /// a notice and sends nothing ("a warmup failure rejects",
    /// dsh-client-ui-commands client.js:699-711, 733), while a servable catalog
    /// that does not claim the line - an unknown name (:735) or trailing
    /// arguments on a command that declares no input line (:751) - hands the
    /// snapshot to the ordinary message path. Admission is the only immediate
    /// answer: the lifecycle (`command/run` / `command/done`) is durably
    /// logged and folds into the transcript, so a successful command is never
    /// echoed here. A refused or errored invocation that carried attachments
    /// leaves the draft and the attachments in place for correction, like the
    /// reference client.
    func executeCommand(_ snapshot: ComposerSubmission) async {
        guard !usesNativeHarness, connected, let api, !submitting else { return }
        let text = snapshot.text
        guard parseCommand(text) != nil,
              snapshot.stillApplies(sessionID: selectedID, endpoint: endpoint, catalogGeneration: commandDirectory.catalogGeneration) else { return }
        submitting = true
        defer { submitting = false }
        let descriptors: [CommandDescriptor]
        do { descriptors = try await commandDirectory.ensureReadyAsync(snapshot.sessionID) }
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
        // The wait is exactly where the composer stops being what the user sent
        // from: it may hold another draft, other attachments, another session or
        // another connection by now. None of that belongs to this action, so
        // the decision below is taken on the snapshot alone.
        guard snapshot.stillApplies(sessionID: selectedID, endpoint: endpoint, catalogGeneration: commandDirectory.catalogGeneration) else { return }
        switch resolveCommandDispatch(snapshot, descriptors: descriptors) {
        case .message:
            // A servable catalog that does not claim the line leaves it to the
            // ordinary message path, with the snapshot's own text and
            // attachments - not with whatever the composer holds by now.
            submitting = false
            await submit(snapshot: snapshot)
        case .refusesAttachments(let message):
            error = message
        case .execute(let descriptor):
            await executeClaimedCommand(snapshot, descriptor: descriptor, api: api)
        case .confirmFullAccess(let descriptor):
            // One claimed line is not a command run but a policy change: the
            // dispatch table marks the escalation, and this is the only route
            // that asks - and the answer is what sends it (`FullAccessGate`).
            // Nothing reaches `commands/execute` before the user enables full
            // access.
            requestFullAccess(.command(snapshot, descriptor))
        }
    }

    /// The `commands/execute` leg of one frozen command action: the snapshot's
    /// line and the snapshot's attachments, then the cleanup of exactly what
    /// went out.
    private func executeClaimedCommand(_ snapshot: ComposerSubmission, descriptor: CommandDescriptor, api: HarnessAPI) async {
        guard let submitted = submissionAttachments(snapshot.images) else {
            error = "An attachment cannot be submitted with /" + descriptor.name + "."; return
        }
        func current() -> Bool {
            snapshot.stillApplies(sessionID: selectedID, endpoint: endpoint, catalogGeneration: commandDirectory.catalogGeneration)
        }
        do {
            guard current() else { return }
            let value = try await api.rpc("commands/execute", args: commandExecuteArguments(agentId: snapshot.sessionID, line: snapshot.text, submittedAttachments: submitted))
            let execution = CommandExecution(value)
            // The cleanup of the sending session's saved composer hangs on the
            // Host having taken the command - not on the user still looking at
            // that session: returning to it must not resurrect the command and
            // its attachments. The live composer and the notice below belong to
            // the selected session, so they stay behind `current()`.
            let declined = value == .null || (!snapshot.images.isEmpty && execution.result.isError)
            var liveSentDraft: String?
            if !declined {
                let key = snapshot.imageDraftKey
                if !snapshot.images.isEmpty, let existing = imageDrafts[key] {
                    imageDrafts[key] = snapshot.imagesAfterSend(existing)
                    saveImageDrafts(key: key)
                }
                liveSentDraft = applySentDraftCleanup(snapshot)
            }
            guard current() else { return }
            guard value != .null else { self.error = "Unknown or malformed command: " + snapshot.text; return }
            if !snapshot.images.isEmpty, execution.result.isError {
                self.error = execution.result.text ?? ("/" + descriptor.name + " failed")
                return
            }
            error = nil
            if let liveSentDraft { draft = liveSentDraft }
            if !snapshot.images.isEmpty { images = snapshot.imagesAfterSend(images) }
        } catch { if current() { self.error = error.localizedDescription } }
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
    /// Send one message. `snapshot` is the composer state a send action froze
    /// before its first suspension; a caller that does not freeze one (the steer
    /// menu, the live probes, the native path) leaves it nil and the live
    /// composer is read here instead, in one main-actor statement. Either way
    /// this call reads the composer exactly once: the RPC payload and the
    /// cleanup below both work from that value.
    func submit(mode: String = "queue", snapshot: ComposerSubmission? = nil) async {
        // The native queue is its own flow, and a frozen DSH snapshot is never
        // re-homed onto it: that send belonged to the DSH connection the
        // snapshot names, so a backend switch between the tap and this call
        // cancels the action instead of sending whatever the native composer
        // holds by now. A caller that froze nothing (the native path itself)
        // still reaches the native send.
        if native != nil {
            if snapshot != nil { return }
            await submitNative(mode: mode); return
        }
        guard !usesNativeHarness, let api, connected, let id = selectedID, !submitting else { return }
        guard !preparingImages, !selectingModel else { return }
        let frozen = snapshot ?? ComposerSubmission(draft: draft, images: images, sessionID: id, endpoint: endpoint, catalogGeneration: commandDirectory.catalogGeneration, draftVersion: draftTable.version(of: id))
        // A snapshot of another session - or of a connection that has since been
        // torn down - is never sent here: the user moved on and this action is
        // not theirs any more.
        guard frozen.stillApplies(sessionID: id, endpoint: endpoint, catalogGeneration: commandDirectory.catalogGeneration) else { return }
        let text = frozen.text
        guard !text.isEmpty || !frozen.images.isEmpty else { return }
        let sendingImages = frozen.images
        do { try imageLimits.validate(sendingImages) } catch { self.error = error.localizedDescription; return }
        // A timeout keeps the same identity and text for an explicit retry, never an automatic resend.
        let request = pendingRequest.flatMap { frozen.isRetry(of: $0) ? $0 : nil } ?? (id: UUID().uuidString, text: text, session: id, imageIDs: frozen.imageIDs)
        pendingRequest = request; pendingText = text.isEmpty ? "Image" : text; submitting = true
        defer { submitting = false }
        do {
            _ = try await api.rpc("session/prompt", args: ["request": .object(["sessionId": .string(id), "requestId": .string(request.id), "mode": .string(mode), "clientTimeZone": .string(TimeZone.current.identifier), "content": .array(promptContent(frozen))])])
            // A successful send removes exactly what it sent. The sending
            // session is the one whose saved composer it cleans: that session's
            // draft line and saved attachments go even if the user selected
            // another session while the RPC was in flight - returning to it
            // must not resurrect a message that already left - while the live
            // composer is touched only while it still shows that session.
            var liveSentDraft: String?
            if endpoint == frozen.endpoint {
                let key = frozen.imageDraftKey
                if let existing = imageDrafts[key] {
                    imageDrafts[key] = frozen.imagesAfterSend(existing)
                    saveImageDrafts(key: key)
                }
                liveSentDraft = applySentDraftCleanup(frozen)
            }
            guard frozen.stillApplies(sessionID: selectedID, endpoint: endpoint, catalogGeneration: commandDirectory.catalogGeneration) else { return }
            images = frozen.imagesAfterSend(images)
            if let liveSentDraft { draft = liveSentDraft }
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
    /// The transport vanished mid-selection: the request went out on a
    /// connection that is already gone. The liveness check sees the same
    /// disconnect, so the operation settles stale instead of surfacing this.
    private struct SelectionTransportGone: LocalizedError {
        var errorDescription: String? { "The connection dropped before the model selection was confirmed." }
    }
    func selectModel(provider: String, model: String, effort: String? = nil) async {
        if usesNativeHarness { error = "Native Harness currently uses the model configured on its host: " + modelLabel; return }
        guard api != nil, connected, let id = selectedID else { return }
        // A selection may supersede the in-flight one: the gate owns the busy
        // flag, and only the still-active operation may release it or land a
        // response, so a second tap is safe and the first becomes stale.
        let generation = self.generation
        var lastError: Error?
        let result = await selection.select(provider: provider, model: model, effort: effort,
                                            sessionID: id, endpoint: endpoint, generation: generation, epoch: selectionEpoch, attempt: carrier.currentRefreshToken(),
                                            onBusy: { [weak self] in self?.selectingModel = $0 },
                                            rpc: { [weak self] method, args in
                                                guard let api = self?.api else { throw SelectionTransportGone() }
                                                do { return try await api.rpc(method, args: args) } catch { lastError = error; throw error }
                                            },
                                            live: { [weak self] op in self?.isLiveModelSelection(op) ?? false },
                                            onAccepted: { [weak self] value in
                                                guard let self, self.selectedID == id else { return }
                                                self.model = value["selected"]
                                            },
                                            onCatalog: { [weak self] value in
                                                guard let self, self.selectedID == id else { return }
                                                self.catalog = value
                                            })
        switch result.outcome {
        case .applied, .catalogFailed:
            error = result.outcome == .applied ? nil : "Model selected, but the catalog did not refresh."
            await refresh()
            if isLiveModelSelection(result.operation) { do { try await followSelected() } catch {} }
        case .rejected:
            error = "Could not confirm the selected model: " + (lastError?.localizedDescription ?? "request failed")
        case .stale:
            break
        }
    }
    private func command(_ name: String, request: [String: JSON]) async {
        guard connected, let api else { return }
        do { _ = try await api.rpc(name, args: ["request": .object(request)]) } catch { self.error = error.localizedDescription }
    }
    /// Whether a pending model selection is still on the live session and
    /// connection it was sent on: the session, endpoint, connection
    /// generation and selection epoch all match, and the carrier still accepts
    /// the attempt the request rode on (nil = pre-carrier, always accepted).
    private func isLiveModelSelection(_ op: ModelSelectionGate.Operation) -> Bool {
        guard connected, api != nil else { return false }
        return op.sessionID == selectedID
            && op.endpoint == endpoint
            && op.generation == generation
            && op.epoch == selectionEpoch
            && carrier.accepts(op.attempt)
    }
    /// The store's live session and connection as one value: what a pending
    /// action is checked against when its question is answered.
    var liveConnectionIdentity: LiveConnectionIdentity {
        LiveConnectionIdentity(sessionID: selectedID, endpoint: endpoint, catalogGeneration: commandDirectory.catalogGeneration)
    }

    /// Ask the user to confirm one access escalation. The pending question is
    /// bound to the action's own snapshot, so the composer can keep being edited
    /// while it is on screen, and a second request while one is unanswered is
    /// refused instead of replacing it.
    func requestFullAccess(_ target: FullAccessGate.Target) {
        guard let pending = fullAccessGate.request(target) else { return }
        accessConfirmation = pending
    }

    /// The user declined the pending escalation: nothing is sent, and the
    /// composer keeps exactly the draft and attachments it held.
    func cancelFullAccess(_ id: UUID) {
        guard accessConfirmation?.id == id, fullAccessGate.cancel(id: id) else { return }
        accessConfirmation = nil
    }

    /// Answer the pending escalation. The gate runs at most one action per
    /// confirmation and drops a late, doubled or stale answer; the transports
    /// below are the two legs the question guarded.
    func confirmFullAccess(_ id: UUID) async {
        // A question that is no longer the current one is not answerable: the
        // answer arriving for a replaced or withdrawn confirmation must not
        // consume it on the user's behalf.
        guard accessConfirmation?.id == id else { return }
        accessConfirmation = nil
        let live = connected ? liveConnectionIdentity : nil
        let outcome = await fullAccessGate.confirm(id: id, live: live, busy: submitting, command: { [weak self] snapshot, descriptor in
            guard let self, !self.submitting, self.connected, let api = self.api else { return }
            self.submitting = true
            defer { self.submitting = false }
            await self.executeClaimedCommand(snapshot, descriptor: descriptor, api: api)
        }, approval: { [weak self] item in
            guard let self else { return }
            self.fullAccessExecuting = true
            defer { self.fullAccessExecuting = false }
            if await self.enableFullAccess(for: item) { await self.answer(item, value: .string("allowed-once")) }
        })
        // The answer found no action to run - the session or the connection moved
        // under the question, or another send owns the store - so nothing was
        // enabled or sent. Saying so beats a dialog that closes as if it had
        // worked.
        if outcome == .rejected { error = "Full access was not enabled: the session or the connection changed. Send it again." }
    }

    /// Drop an unanswered escalation question without a decision. Its action
    /// names one session and one connection generation, and neither survives the
    /// question: after a switch, a reconnect or a teardown there is nothing left
    /// for the user to be answering.
    private func clearAccessConfirmation() {
        confirmationLifecycle.reset()
        accessConfirmation = nil
    }

    /// The `commands/execute` leg behind a confirmed escalation, for the
    /// approval card that sits on a live request.
    func enableFullAccess(for item: Interaction) async -> Bool {
        guard let api, connected, item.sessionID == selectedID, item.clientID == clientID,
              interactions.contains(where: { $0.id == item.id }) else { return false }
        do {
            let value = try await api.rpc("commands/execute", args: commandExecuteArguments(agentId: item.sessionID,
                line: FullAccessPolicy.commandLine, submittedAttachments: []))
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
            if savedDrafts[submission.session]?.trimmingCharacters(in: .whitespacesAndNewlines) == submission.draft {
                draftTable.write("", for: submission.session)
                persistDrafts()
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
