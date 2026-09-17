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
    /// Readable (not private) so the offline checks can verify the focus a
    /// create captured for its own session.
    private(set) var newlyCreatedSession: String?
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
    /// B3: a blank-session preset switch is in flight: the composer's send,
    /// the command dispatch and the model selection are all blocked until the
    /// Host has answered the switch - the blank window closes the moment the
    /// accepted projection lands.
    @Published private(set) var switchingPreset = false
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
    /// Internal (not private) so the offline checks can drive the production
    /// selection path through a delayed fake transport.
    var api: HarnessAPI?
    /// Internal (not private) so the offline checks can drive the production
    /// create branch through the same path the native sheet uses.
    var native: NativeChatConnection?
    /// Bounded seam for the native create's open frame: nil in production,
    /// where the open goes through the live connection. The offline checks
    /// park or fail it to test the open's real outcome.
    var nativeOpenSeam: ((NativeCommand) async throws -> Void)?
    /// The host replies that reached the store while a create's open was
    /// still in flight - between the open frame going out and the create's
    /// commit, when the admission gate still names the prior selection and
    /// would drop them. Owned by that open: parked here, replayed by its
    /// commit, dropped by its failure or a lost seat. Bounded; frames past
    /// the limit are the newest, and the prefix is the admission-critical
    /// one (opened, synced, the first history).
    /// The frames parked for a create's open. The decision frames - the
    /// host's opened answer, a session-scoped rejection and the terminal
    /// synced - live in their own slots: a history overflow can never drop
    /// them. The history between them is a bounded window; an overflow drops
    /// the oldest frame and marks the buffer truncated, which the commit
    /// surfaces as a gap on the replayed opened frame - the host's own
    /// truncation semantics - instead of a silently complete transcript.
    private struct PendingNativeOpen {
        let sessionID: String
        let operation: CreateOperation
        var opened: NativeEvent?
        var history: [NativeEvent]
        var historyDropped = false
        var terminalSynced: NativeEvent?
        var rejection: NativeEvent?
    }
    private var pendingNativeOpen: PendingNativeOpen?
    /// The bounded history window of the parked buffer. The decision frames
    /// live outside it and are never dropped.
    private static let pendingNativeOpenLimit = 256
    /// The host's decision on a parked open: opened, rejected, or lost to a
    /// seat the create no longer holds. The create suspends on it - no sleep,
    /// no timeout: a host that answers neither opened nor error leaves the
    /// create suspended until the seat is lost, and every seat loss resolves
    /// the wait, so it can hang on no host.
    private var pendingOpenDecision: CheckedContinuation<PendingOpenResult, Never>?
    private enum PendingOpenResult { case opened, rejected, lost }
    private func resumePendingOpenDecision(_ result: PendingOpenResult) {
        guard let continuation = pendingOpenDecision else { return }
        pendingOpenDecision = nil
        continuation.resume(returning: result)
    }
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
    /// Read-only observation of the native transcript fold for the
    /// parked-open checks: a value copy of the private state, nothing else
    /// - the checks compare full presentation snapshots before and after a
    /// create, and the fold's rows are part of the presentation.
    var nativeTranscriptObservation: NativeTranscript { nativeTranscript }
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
    var generation = UUID()
    /// The session-selection epoch: rotates on every session switch and on
    /// disconnect, so a deferred selectModel response cannot revive an old
    /// session's request just because the session id matches again.
    var selectionEpoch = UUID()
    /// The selection this store last started. The post-response effects -
    /// error, list refresh, stream follow - belong only to the operation that
    /// still holds this seat.
    private(set) var activeSelection: ModelSelectionGate.Operation?
    /// The Remote carrier's stream identity: which socket attempt is live,
    /// which IDs its streams carry, and which ping/refresh work may still
    /// report. The socket and the UI stay here; every "whose frame is this"
    /// decision lives in the coordinator, which the offline gates compile.
    let carrier = RemoteStreamConnection()
    /// The async model-selection path with operation ownership: who owns the
    /// busy flag, and which deferred response may still land.
    let selection = ModelSelectionGate()
    /// The production owner of the in-flight session Create: the seat a
    /// create takes before its first await and the outcome it settles into.
    /// A session switch or a disconnect drops the seat, so a late answer can
    /// apply nothing.
    let createSeat = CreateSheetOwnership()
    /// B3: the async preset-switch path with operation ownership: who owns
    /// the busy flag, and which deferred response may still land. The
    /// accepted preset itself is never stored here - it is the server-owned
    /// `agentPreset` projection on the session list (see acceptedAgentPreset).
    let presetSwitch = PresetSwitchGate()
    /// The switch this store last started. The post-response effects - error,
    /// list refresh, catalog and re-follow - belong only to the operation
    /// that still holds this seat.
    private(set) var activePresetSwitch: PresetSwitchGate.Operation?
    /// C1: the async session-control path with operation ownership: the
    /// seat a control click takes before any suspension, and the frozen
    /// projection it dispatches from. The state it changes is the
    /// server-owned permissions/plan projection, never stored from the
    /// client side.
    let controls = SessionControlGate()
    /// The control action this store last started: its post-response
    /// effects - the published outcome and the visible error - belong only
    /// to the operation that still holds this seat.
    private(set) var activeControl: SessionControlOperation?
    /// C1: the last control action's outcome, for the UI that renders the
    /// controls and for the checks. The outcome is the dispatch's result,
    /// never a projection: the server frame moves the state.
    @Published private(set) var controlOutcome: SessionControlOutcome?
    /// C1: the last error the control lineage wrote, with the operation that
    /// wrote it. A settled control clears exactly this message - never an
    /// error another subsystem published over it - and a session switch or a
    /// disconnect retires the error with the lineage that owned it.
    private var controlError: (operation: SessionControlOperation, message: String)?
    /// The newest agentPresets/list pull this store has issued. A pull that
    /// answers after a newer pull on the same connection belongs to no one:
    /// the picker keeps the roster the latest request fetched. A control
    /// question frozen on an older pull is stale the moment a newer one
    /// starts: the capability facts it read no longer name the live roster,
    /// so the question is retired with the seat it held.
    private var presetRosterPull = 0 { didSet { retireStaleControlQuestion() } }
    /// The preset roster as agentPresets/list served it on the live
    /// connection. The picker re-pulls it on open, so it is never a cache.
    @Published private(set) var presetRoster: AgentPresetRosterState = .missing
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
    var projectionStores: [String: SessionProjectionStore] = [:]
    /// The per-session command catalog (`commands/list`), epoch-guarded by the
    /// ported CommandDirectory. Created on first use and never replaced, so a
    /// pull always has somewhere to publish and a strong-wait can never be
    /// stranded on a missing directory.
    lazy var commandDirectory = CommandDirectory(startPull: { [weak self] token in
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
    /// B3: the selected session's accepted preset, as the Host owns it: the
    /// `agentPreset` projection from the session list. nil is "runs on the
    /// deployment default". The picker's staged choice never appears here -
    /// only what the Host accepted for this session is shown, and the id is
    /// displayed verbatim when the roster no longer advertises it.
    var acceptedAgentPreset: String? {
        let id = selected?.raw["projections"]["values"]["agentPreset"].string ?? ""
        return id.isEmpty ? nil : id
    }
    /// B3: the Host's own fact about the blank window. Only this makes the
    /// session switchable - never `!running`, never an empty transcript.
    var selectedIsBlank: Bool {
        selected?.raw["projections"]["values"]["sessionListMetadata"]["blank"].bool ?? false
    }
    /// B3: the switcher's label: the accepted preset's display name, or the
    /// word itself when the session runs on the deployment default.
    var presetSwitcherLabel: String {
        acceptedAgentPreset.map { presetDisplayName($0, roster: presetRoster) } ?? "Preset"
    }
    /// B3: where the switcher lives: a connected DSH session in its blank
    /// window. A non-blank session has left the window - the Host owns that
    /// fact, and the switcher with it.
    var presetSwitcherVisible: Bool {
        connected && !usesNativeHarness && selected != nil && selectedIsBlank
    }
    /// B3: the switcher's menu options: the advertised rows in the order the
    /// Host serves them, with the accepted preset itself first, verbatim, when
    /// the roster no longer advertises it - the unknown-id fallback. The
    /// untappable "Server default" row appears only while the session runs on
    /// the deployment default: the wire carries a non-empty id, and that is
    /// the default row the roster serves.
    var presetSwitcherOptions: [PresetPickerOption] {
        let staged = acceptedAgentPreset
        let options = PresetSelection.pickerOptions(roster: presetRoster, staged: staged)
        return staged == nil ? options : options.filter { $0.presetID != nil }
    }
    /// B3: one list row's accepted preset name for the home display: nil when
    /// the row runs on the deployment default; the id verbatim when the
    /// roster no longer advertises it.
    func acceptedPresetName(for session: HarnessSession) -> String? {
        let id = session.raw["projections"]["values"]["agentPreset"].string
        return id.isEmpty ? nil : presetDisplayName(id, roster: presetRoster)
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
            // The roster belongs to the connection: pull it now so the
            // picker already holds the advertised presets when it opens.
            Task { await refreshPresetRoster() }
        } catch { if attempt == generation { self.error = error.localizedDescription; connecting = false; connectionDiagnostic("connect-failed", error: error) } }
    }
    func disconnect() {
        nativeReconnect?.cancel(); nativeReconnect = nil
        generation = UUID(); selectionEpoch = UUID(); connectionTask?.cancel(); connectionTask = nil
        // The in-flight selection rode the connection that just died: drop
        // its ownership and busy state immediately, so the UI never waits for
        // a dead request's response to re-enable the controls.
        selection.invalidateCurrent(); activeSelection = nil
        presetSwitch.invalidateCurrent(); activePresetSwitch = nil
        controls.invalidate(); activeControl = nil
        // The control's settled state belonged to the connection that just
        // died: the reconnected store starts it clean, and a control-owned
        // error goes with the lineage that wrote it.
        controlOutcome = nil
        if let owned = controlError, error == owned.message { error = nil }
        controlError = nil
        // The in-flight create rode this connection too: drop its seat so a
        // late answer applies nothing, and retire the roster it was served on.
        createSeat.invalidate()
        // A create suspended on its open's decision rode this connection: the
        // dead connection decides it.
        resumePendingOpenDecision(.lost)
        presetRoster = .missing
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
                self.confirmationLifecycle.carrierFailed(); self.clearAccessConfirmation()
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
                confirmationLifecycle.attemptReady(); clearAccessConfirmation()
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
    /// before the new values land; a history snapshot is a plain seed. The fold
    /// is the production seam a baseline removal takes, so it retires a
    /// control question whose capability the new values dropped. Internal,
    /// not private, so the offline checks fold through this exact path.
    func applyProjection(_ sid: String, p: JSON, replacement: Bool = false) {
        let baseline = ProjectionBaseline(p)
        var store = projectionStores[sid] ?? SessionProjectionStore()
        let previous = store.rows
        if replacement { store.truncate(lastSeq: baseline.asOfSeq) }
        store.seed(baseline: baseline)
        projectionStores[sid] = store
        for (key, row) in store.rows where previous[key] != row { patchProjection(sid, key: key, value: row.value) }
        for key in previous.keys where store.rows[key] == nil { dropProjection(sid, key: key) }
        retireStaleControlQuestion()
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
    /// live at this moment. `selection`, when given, is the model selection
    /// that asked for the list: its result - success or failure - then applies
    /// only while that selection still owns the seat, so a list that lands
    /// after a newer selection started belongs to no one. `create`, when
    /// given, is the create operation that asked for the list: its result then
    /// applies only while that create still holds the sheet's seat, so a list
    /// parked across a sheet close or a supersede belongs to no one. Either
    /// way a result - success or failure - is applied only while the
    /// connection identity still holds, so a list that arrives after a
    /// reconnect belongs to the connection that asked for it.
    func refresh(token: RemoteStreamConnection.RefreshToken? = nil, selection: ModelSelectionGate.Operation? = nil, create: CreateOperation? = nil) async {
        if let native { do { try await native.send(NativeCommand(op: "list")) } catch { self.error = error.localizedDescription }; return }
        guard let api else { return }
        let connection = generation
        let refresh = token ?? carrier.currentRefreshToken()
        do {
            let result = try await api.rpc("session/list", args: ["_request": .object([:])])
            guard generation == connection, carrier.accepts(refresh), selectionOwnershipHolds(selection), createOwnershipHolds(create) else { return }
            sessions = result["items"].array.map { HarnessSession(raw: $0) }
        } catch {
            guard generation == connection, carrier.accepts(refresh), selectionOwnershipHolds(selection), createOwnershipHolds(create) else { return }
            self.error = error.localizedDescription
        }
    }
    /// Whether the selection that asked for a refresh still owns the seat: it
    /// must be the store's latest selection and still live on its session and
    /// connection. A stale one writes no list and no error.
    private func selectionOwnershipHolds(_ selection: ModelSelectionGate.Operation?) -> Bool {
        guard let selection else { return true }
        return activeSelection === selection && isLiveModelSelection(selection)
    }
    /// Whether the create that asked for a refresh still holds the sheet's
    /// seat. A refresh parked across a sheet close or a supersede writes no
    /// list and no error for a create that no longer owns the sheet.
    private func createOwnershipHolds(_ create: CreateOperation?) -> Bool {
        guard let create else { return true }
        return createSeat.stillOwns(create)
    }
    @discardableResult
    func select(_ id: String?, createSelfSelect: CreateOperation? = nil) async -> NativeOpenOutcome {
        #if DEBUG
        if let replay = ProcessInfo.processInfo.environment["DSH_NATIVE_REPLAY"] { loadNativeReplay(replay); return .none }
        if ProcessInfo.processInfo.environment["DSH_DEMO"] == "1" { loadDemo(); selectedID = id; return .none }
        #endif
        applySelection(id, createSelfSelect)
        guard connected else { return .none }
        if let native {
            resetNativePresentation(id)
            guard let id else { return .none }
            // The open's confirmation is the create's success: a rejected
            // open publishes the error and reports .failed, a confirmed one
            // reports .opened. The seam is nil in production.
            let open = NativeCommand(op: "open", session: id)
            do {
                if let nativeOpenSeam { try await nativeOpenSeam(open) }
                else { try await native.send(open) }
                return .opened
            }
            catch {
                // A create's self-select publishes the error only while its
                // operation still owns the seat: a closed or superseded
                // create must not write a global error over the newer
                // sheet. An ordinary select always publishes it.
                if let op = createSelfSelect, !createSeat.stillOwns(op) {} else {
                    self.error = error.localizedDescription
                }
                loadingHistory = false
                return .failed
            }
        }
        do { try await followSelected() } catch { self.error = error.localizedDescription; loadingHistory = false }
        return .none
    }
    /// The selection transition: what adopting a session publishes - the
    /// epoch rotation, the composer and roster reset, the model and the
    /// command catalog. An ordinary select applies it before its open,
    /// exactly as before this split; the create-owned native open applies it
    /// only as its commit, after the open confirmed and the seat still
    /// holds.
    private func applySelection(_ id: String?, _ createSelfSelect: CreateOperation?) {
        // Rotate the epoch only on a real session switch: reselecting the
        // current session keeps its in-flight selection live, while A -> B -> A
        // still invalidates the original request - its epoch is gone even
        // though the session id matches again. A switch by someone else also
        // drops the in-flight create's seat: its answer must not steal the
        // selection. The create's own self-select keeps the seat, though: its
        // follow is exactly where a sheet close or a user switch can still
        // retire it, and the settled outcome is judged against that seat.
        if selectedID != id {
            selectionEpoch = UUID(); selection.invalidateCurrent(); activeSelection = nil
            // The in-flight switch rode the session the user just left: drop
            // its seat so its answer applies nothing, the way the selection's.
            presetSwitch.invalidateCurrent(); activePresetSwitch = nil
            // The in-flight control rode this session too: its answer must
            // not land on the session that replaced it, and neither may a
            // settled outcome or a control-owned error it left behind.
            controls.invalidate(); activeControl = nil
            controlOutcome = nil
            if let owned = controlError, error == owned.message { error = nil }
            controlError = nil
            if createSelfSelect == nil || createSeat.active?.id != createSelfSelect?.id {
                createSeat.invalidate()
                // The create's answer must not wait on a seat it no longer holds.
                resumePendingOpenDecision(.lost)
            }
        }
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
    }
    /// The native presentation a selection applies: a fresh transcript and
    /// requests, an emptied queue, diff and interactions, the terminal's
    /// readiness dropped until the host re-advertises it - and the
    /// connection pointed at the session, its history load started.
    private func resetNativePresentation(_ id: String?) {
        guard let native else { return }
        nativeReady = false; nativeTranscript = NativeTranscript(); nativeRequests = []; nativeProtocolNotices = []; nativeCompaction = nil; nativeSupportsCompaction = false; nativeCompactionPending = false; nativeQueue = []; nativeQueueOmitted = 0; nativeSupportsQueue = false; nativeDiff = nil; nativeSupportsDiff = false; nativeDiffLoading = false; nativeDiffTimeout?.cancel(); nativeDiffTimeout = nil; interactions = []
        native.selectedID = id
        if id != nil { loadingHistory = true }
    }
    /// The create-owned native open, transactional in three steps:
    /// prepare - nothing user-visible is published; the open frame for the
    /// generated ID is all that gets built;
    /// decide - exactly one frame goes out, through the seam in the checks
    /// and the live connection in production; the send confirmation covers
    /// only the local socket write, so the create then suspends on the
    /// host's decision - its opened frame, a session-scoped rejection, or
    /// the seat going out from under it; no sleep, no timeout: a host that
    /// answers neither leaves the create suspended until the seat is lost,
    /// and every seat loss (sheet close, disconnect, session switch, newer
    /// create) resolves the wait, so it can hang on no host;
    /// commit - only after the host's opened AND the same operation still
    /// owns the seat, the full selection transition applies, locally,
    /// without a second open. A lost seat returns .none - the open was
    /// abandoned, and the create's own seat guard settles .stale; a
    /// rejected open publishes its error while the seat still holds and
    /// returns .failed. In both cases nothing was adopted, so there is
    /// nothing to restore.
    /// The decision frames park in the open's buffer from before the frame
    /// goes out: the connection's independent reader task can decode the
    /// host's answer - opened, synced, the history replay - while the open
    /// await is still suspended, when the selection still names the prior
    /// session and the admission gate would drop every one of those frames,
    /// leaving the new session shell-less with its history load stuck. The
    /// opened answer, the rejection and the terminal synced live in their
    /// own slots, so a history overflow can never drop them; the history
    /// between them is a bounded window, and an overflow drops the oldest
    /// frame and marks the buffer truncated, which the commit surfaces as a
    /// gap on the replayed opened frame - the host's own truncation
    /// semantics. A lost seat or a rejection drops the buffer with the
    /// open: nothing was adopted, and the abandoned session's events admit
    /// against the old selection as before.
    private func createNativeOpen(_ id: String, createSelfSelect op: CreateOperation) async -> NativeOpenOutcome {
        let open = NativeCommand(op: "open", session: id)
        pendingNativeOpen = PendingNativeOpen(sessionID: id, operation: op, opened: nil, history: [],
                                              historyDropped: false, terminalSynced: nil, rejection: nil)
        do {
            if let nativeOpenSeam { try await nativeOpenSeam(open) }
            else { try await native!.send(open) }
        }
        catch {
            settlePendingNativeOpen(op, sessionID: id)
            // A rejected open publishes the error only while the create
            // still owns the sheet: a closed or superseded create writes no
            // error over the newer sheet.
            if createSeat.stillOwns(op) { self.error = error.localizedDescription }
            return .failed
        }
        // The send confirmed the socket write, not the open. Wait for the
        // host's decision on it: its opened frame, a session-scoped
        // rejection, or the seat going out from under the create.
        let decision = await withCheckedContinuation { continuation in
            pendingOpenDecision = continuation
            if let pending = pendingNativeOpen, pending.sessionID == id, pending.operation.id == op.id {
                if pending.opened != nil { resumePendingOpenDecision(.opened) }
                else if pending.rejection != nil { resumePendingOpenDecision(.rejected) }
            }
            // The seat may have gone out between the send returning and the
            // wait parking: a lost seat decides the open without waiting.
            if pendingOpenDecision != nil, !createSeat.stillOwns(op) { resumePendingOpenDecision(.lost) }
        }
        switch decision {
        case .opened:
            guard createSeat.stillOwns(op) else { settlePendingNativeOpen(op, sessionID: id); return .none }
            return commitPendingNativeOpen(id, createSelfSelect: op)
        case .rejected:
            settlePendingNativeOpen(op, sessionID: id)
            guard createSeat.stillOwns(op) else { return .none }
            return .failed
        case .lost:
            settlePendingNativeOpen(op, sessionID: id)
            guard createSeat.stillOwns(op) else { return .none }
            return .failed
        }
    }
    /// The open's commit, await-free: the full selection transition, then
    /// the parked host reply replays through the production admission path,
    /// which now sees the new selection, in the host's own order - the
    /// opened frame, the retained history, the terminal synced, and the
    /// rejection if the host still rejects.
    private func commitPendingNativeOpen(_ id: String, createSelfSelect op: CreateOperation) -> NativeOpenOutcome {
        applySelection(id, op)
        resetNativePresentation(id)
        if let pending = pendingNativeOpen, pending.sessionID == id, pending.operation.id == op.id {
            pendingNativeOpen = nil
            var opened = pending.opened
            // A history frame the bounded window could not keep is surfaced
            // the way the host surfaces its own truncation: as a gap on the
            // opened frame, so the transcript and the shell both say "only
            // the retained part".
            if opened != nil, pending.historyDropped { opened?.gap = true }
            if let opened { receiveNative(opened) }
            for event in pending.history { receiveNative(event) }
            if let synced = pending.terminalSynced { receiveNative(synced) }
            if let rejection = pending.rejection { receiveNative(rejection) }
        }
        return .opened
    }
    /// Only the open that still owns the seat may clear the buffer it owns -
    /// a newer create's open overwrites the slot, and an older open resuming
    /// late must not clear the buffer the younger one is still filling.
    private func settlePendingNativeOpen(_ op: CreateOperation, sessionID: String) {
        if let pending = pendingNativeOpen, pending.sessionID == sessionID, pending.operation.id == op.id {
            pendingNativeOpen = nil
        }
    }
    /// Observation seam for the conversation follow decision: nil retires the
    /// stream, an id points it at that session. Production leaves it nil; the
    /// parked-transport checks count calls to prove which selection's
    /// continuation actually moved the live conversation.
    var conversationFollowObservation: (@MainActor (String?) -> Void)?
    /// The stream transport the conversation follow drives. Production is the
    /// live socket; the offline checks substitute a parked one, so a follow
    /// can be held open across a session switch or a reconnect - exactly what
    /// a slow socket would hold it across.
    var followTransport: RemoteStreamTransport?
    /// Point the conversation stream at the selected session. The previous ID
    /// is retired before the first suspension, so frames of the session the
    /// user just left - its snapshot, its events, its errors - are discarded
    /// from the moment the switch is decided. A deselect retires the stream
    /// without opening another one.
    private func followSelected() async throws {
        guard let transport = followTransport ?? socket else {
            // No socket to tell: the ID is still retired, so nothing can
            // arrive for it later.
            conversationFollowObservation?(nil)
            try await carrier.cancel(.conversation, on: nil)
            return
        }
        guard let id = selectedID else {
            loadingHistory = false
            conversationFollowObservation?(nil)
            try await carrier.cancel(.conversation, on: transport)
            return
        }
        loadingHistory = true
        conversationFollowObservation?(id)
        try await carrier.subscribe(.conversation, endpoint: "session/follow", args: ["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(id)]), "maxMessages": .number(50), "assistantStream": .bool(true)])], on: transport)
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
        guard !usesNativeHarness, connected, let api, !submitting, !switchingPreset else { return }
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
        _ = await create(workspaceID: nil)
        focusNewSessionComposer()
    }
    /// The store's live connection as seen by a Create operation: the
    /// endpoint, generation and selection epoch captured when the operation
    /// was issued must still be the live ones, and the carrier must still
    /// accept the attempt it captured.
    private func isLiveCreate(_ op: CreateOperation) -> Bool {
        guard connected, api != nil else { return false }
        return op.endpoint == endpoint
            && op.generation == generation
            && op.epoch == selectionEpoch
            && carrier.accepts(op.attempt)
    }
    /// Whether the create's own select can still settle. The self-select kept
    /// the sheet's seat, so the seat judges the outcome: the connection
    /// identity the operation captured must still stand, the create must still
    /// hold the seat - a sheet close or a user switch during the follow
    /// retires it - and the selection it asked for must still be the selected
    /// session. A close, a switch or a reconnect stales the create; a
    /// legitimate select still settles it.
    private func isSettledCreateSelection(_ op: CreateOperation, sessionID: String) -> Bool {
        guard connected, api != nil else { return false }
        guard op.endpoint == endpoint, op.generation == generation, carrier.accepts(op.attempt) else { return false }
        guard createSeat.stillOwns(op) else { return false }
        return selectedID == sessionID
    }
    /// Create one session and return the outcome of THIS create, owned by the
    /// operation it was issued under. Everything the outcome depends on - the
    /// requested identity, the workspace and preset the caller chose, the
    /// connection generation, the selection epoch and the carrier attempt -
    /// is captured before the first await, and the ownership is re-checked
    /// after every await below: a superseded create, a session switch, an
    /// endpoint change or a reconnect can land nothing - no selection, no
    /// list refresh, no error, no composer focus - and the caller's sheet
    /// stays open.
    func create(workspaceID: String? = nil, presetID: String? = nil) async -> CreateResult {
        let op = CreateOperation(id: UUID(), requestedSessionID: "session-" + UUID().uuidString.lowercased(),
                                 workspaceID: workspaceID, agentPreset: presetID,
                                 endpoint: endpoint, generation: generation,
                                 epoch: selectionEpoch, attempt: carrier.currentRefreshToken())
        if native != nil, connected {
            // The native path is local: no session/create on the wire, no
            // refresh, no focus until the native open lands.
            createSeat.begin(op)
            // A newer create supersedes any parked open's wait on its decision.
            resumePendingOpenDecision(.lost)
            let id = UUID().uuidString
            // The create's open is transactional: nothing is published or
            // adopted until the open confirmed and the same operation still
            // owns the seat - the native equivalent of the DSH path only
            // selecting after its answer. A sheet close or a user switch
            // during the open retires the create, and the outcome is judged
            // against that seat after the open lands.
            let opened = await createNativeOpen(id, createSelfSelect: op)
            // The seat judges the outcome, exactly like the DSH path: a
            // sheet close or a user switch during the open stales the
            // create. The open may have created the remote session before
            // that local cancellation: nothing here retries it, and nothing
            // is adopted.
            guard createSeat.stillOwns(op) else {
                let result = CreateResult(operation: op, outcome: .stale)
                createSeat.settle(op, .stale)
                return result
            }
            // The seat holds: the open's confirmation is the create's
            // success. A rejected open is a visible failure - the open
            // published the error while it still owned the seat - and the
            // sheet stays open. Nothing was adopted on the way there, so
            // nothing is restored, and no open frame goes to the prior
            // session: the native protocol asks for none on a create
            // failure, so the prior session is not re-opened as a retry and
            // its transcript is not re-fetched here.
            guard opened == .opened else {
                let message = error ?? "The native session could not be opened."
                let result = CreateResult(operation: op, outcome: .failed(message))
                createSeat.settle(op, .failed(message))
                return result
            }
            // Only a confirmed open of this create focuses the composer.
            if selectedID == id { newlyCreatedSession = id }
            let result = CreateResult(operation: op, outcome: .created(sessionID: id, agentPreset: nil))
            createSeat.settle(op, result.outcome)
            return result
        }
        guard let api, connected else {
            return CreateResult(operation: op, outcome: .failed("Connect to DSH and create the task again."))
        }
        createSeat.begin(op)
        // A newer create supersedes any parked open's wait on its decision.
        resumePendingOpenDecision(.lost)
        do {
            let value = try await api.rpc("session/create", args: ["request": .object(
                PresetSelection.createRequest(sessionID: op.requestedSessionID, workspaceID: workspaceID, agentPreset: presetID))])
            // The answer is this create's only while the operation still
            // holds the seat and its captured context is still live.
            guard isLiveCreate(op), createSeat.stillOwns(op) else {
                let result = CreateResult(operation: op, outcome: .stale)
                createSeat.settle(op, .stale)
                return result
            }
            let sessionID = value["sessionId"].string
            guard !sessionID.isEmpty else {
                let message = "DSH: the create answer named no session."
                self.error = message
                let result = CreateResult(operation: op, outcome: .failed(message))
                createSeat.settle(op, .failed(message))
                return result
            }
            await refresh(create: op)
            // The switch can land between the answer and the select: only
            // the operation that still owns the seat may move the selection.
            guard isLiveCreate(op), createSeat.stillOwns(op) else {
                let result = CreateResult(operation: op, outcome: .stale)
                createSeat.settle(op, .stale)
                return result
            }
            await select(sessionID, createSelfSelect: op)
            // The self-select kept the sheet's seat, so the seat judges the
            // outcome: a sheet close or a user switch during the follow
            // stales the create, a legitimate select still settles it.
            guard isSettledCreateSelection(op, sessionID: sessionID) else {
                let result = CreateResult(operation: op, outcome: .stale)
                createSeat.settle(op, .stale)
                return result
            }
            newlyCreatedSession = sessionID
            let preset = value["agentPreset"].string
            let result = CreateResult(operation: op, outcome: .created(sessionID: sessionID, agentPreset: preset.isEmpty ? nil : preset))
            createSeat.settle(op, result.outcome)
            return result
        } catch {
            // The answer of a create the user moved on from writes nothing.
            guard isLiveCreate(op), createSeat.stillOwns(op) else {
                let result = CreateResult(operation: op, outcome: .stale)
                createSeat.settle(op, .stale)
                return result
            }
            if let error = error as? HarnessError, error.code == "session/workspace-attach-failed" {
                // The Host created the session, but it could not attach to
                // the requested workspace: refresh the list on this same
                // live connection so the new session is visible. It is not
                // a success, nothing is selected, and the caller does not
                // retry automatically.
                let sessionID = error.details["sessionId"].string
                let workspace = error.details["workspaceId"].string
                await refresh(create: op)
                // The refresh can park across a sheet close or a session
                // switch: only a create that still owns the seat may publish
                // the error and settle attach-failed.
                guard isLiveCreate(op), createSeat.stillOwns(op) else {
                    let result = CreateResult(operation: op, outcome: .stale)
                    createSeat.settle(op, .stale)
                    return result
                }
                let message = error.localizedDescription
                self.error = message
                let result = CreateResult(operation: op, outcome: .attachFailed(sessionID: sessionID.isEmpty ? op.requestedSessionID : sessionID, workspaceID: workspace))
                createSeat.settle(op, result.outcome)
                return result
            }
            let message = error.localizedDescription
            self.error = message
            let result = CreateResult(operation: op, outcome: .failed(message))
            createSeat.settle(op, .failed(message))
            return result
        }
    }
    /// The sheet's close - Cancel or a swipe: the in-flight create, if any,
    /// loses the sheet's seat. That covers both of its waits: an answer
    /// parked before the select, and the create's own follow parked after its
    /// self-select, which kept the seat. Either way the late result settles
    /// stale and can apply no list, no error, no focus and no .created. A
    /// success dismiss is a no-op: the create already settled its seat.
    func retireCreate() {
        createSeat.invalidate()
        // A create suspended on its host's decision must not outlive the
        // sheet: the lost seat decides it.
        resumePendingOpenDecision(.lost)
    }
    /// Load the preset roster from the live connection. The Host re-reads the
    /// roster on every list, so the app keeps no cache of its own: the
    /// picker pulls it on open, and a new connection pulls it again. A fetch
    /// that no longer belongs to the live connection writes nothing, and a
    /// pull superseded by a newer pull on the same connection - the connect
    /// pull answering after the picker's, in either answer order - writes
    /// nothing either, so the picker always shows the roster the latest
    /// request fetched.
    func refreshPresetRoster() async {
        guard let api else { presetRoster = .missing; return }
        let connection = generation
        let attempt = carrier.currentRefreshToken()
        let pull = presetRosterPull + 1
        presetRosterPull = pull
        presetRoster = .loading
        do {
            let value = try await api.rpc("agentPresets/list", args: [:])
            guard generation == connection, carrier.accepts(attempt), pull == presetRosterPull else { return }
            guard value["presets"] != .null else { presetRoster = .missing; return }
            let rows = value["presets"].array.compactMap { AgentPresetRow($0) }
            presetRoster = .loaded(rows: rows, authorable: value["authorable"].bool)
        } catch {
            guard generation == connection, carrier.accepts(attempt), pull == presetRosterPull else { return }
            presetRoster = .failed(error.localizedDescription)
        }
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
        guard !preparingImages, !selectingModel, !switchingPreset else { return }
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
        // A pending preset switch owns the blank window: a model change must
        // not land on a composition the Host is about to replace.
        guard !switchingPreset else { return }
        guard api != nil, connected, let id = selectedID else { return }
        // A selection may supersede the in-flight one: the gate owns the busy
        // flag, and only the still-active operation may release it or land a
        // response, so a second tap is safe and the first becomes stale. The
        // store keeps the same operation instance for its own ownership: the
        // post-response effects below belong only to the selection that still
        // holds the seat when the answer comes back.
        let op = ModelSelectionGate.Operation(sessionID: id, endpoint: endpoint, generation: generation, epoch: selectionEpoch, attempt: carrier.currentRefreshToken())
        activeSelection = op
        var lastError: Error?
        let result = await selection.select(op, provider: provider, model: model, effort: effort,
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
        // The post-response effects - error, list refresh, stream follow - are
        // owned by the operation that still holds the seat: a superseded or
        // invalidated selection writes no error, refreshes no list and
        // follows no stream after a newer request has taken over, or after a
        // session switch or a disconnect dropped it. Ownership is re-checked
        // after every await below: a Boolean captured before the refresh
        // parks goes stale the moment a newer selection takes the seat, and
        // isLiveModelSelection cannot see a same-session supersedure - it
        // rotates no epoch, session, generation or attempt. The gate hands
        // back the very Operation created above, so "op" is the identity to
        // test against.
        switch result.outcome {
        case .applied, .catalogFailed:
            guard activeSelection === op else { break }
            error = result.outcome == .applied ? nil : "Model selected, but the catalog did not refresh."
            await refresh(selection: op)
            guard activeSelection === op, isLiveModelSelection(op) else { break }
            do { try await followSelected() } catch {}
        case .rejected:
            guard activeSelection === op else { break }
            error = "Could not confirm the selected model: " + (lastError?.localizedDescription ?? "request failed")
        default:
            // Stale, or superseded before its response landed: nothing is
            // written; the newer selection - or the invalidation - owns the
            // state now.
            break
        }
    }
    /// B3: the pending-switch ownership of the composer's command window.
    /// The view's command boundary (HarnessView.runCommand) fails closed on
    /// this, so while a preset switch is pending no command action leaves -
    /// a local /new, a /view or /model action, a bare server dispatch - and
    /// it clears the moment the switch settles, so the same commands work
    /// again. The typed server line refuses one hop deeper, on the store's
    /// own executeCommand guard, which reads the same flag.
    var canDispatchCommands: Bool { !switchingPreset }
    /// B3: switch the selected session's accepted preset, the Host's
    /// `agentPresets/select`. The switch is issued only in the blank window -
    /// `selectedIsBlank` is the Host's own fact, never `!running`, never an
    /// empty transcript - and the staged picker choice is sent exactly as the
    /// user chose it. The Host's strict result is the accepted preset id; the
    /// accepted state the UI shows is the `agentPreset` projection the list
    /// refresh below publishes, never the staged value. While the switch is
    /// pending the composer's send, the command dispatch and the model
    /// selection are blocked (the guards above), and a model selection in
    /// flight blocks the switch the same way, as does a composer dispatch
    /// already in flight - the two never interleave on the wire.
    func selectPreset(_ presetID: String) async {
        if usesNativeHarness { return }
        guard api != nil, connected, let id = selectedID else { return }
        // A composer dispatch already in flight owns the blank window the
        // same way the switch does: a send or a command that left before the
        // switch may not interleave with it, so the switch waits for it.
        guard !selectingModel, !submitting else { return }
        // One switch at a time: a second tap before the first answered is a
        // no-op, not a supersede - the menu is disabled while pending anyway,
        // and the blank window ends the moment the accepted projection lands.
        guard activePresetSwitch == nil else { return }
        // C1: the command boundary is one seat. A pending control owns it
        // the way a pending switch does: the switch is refused, not
        // superseded, so the two can never interleave on the wire.
        guard activeControl == nil else { return }
        guard selectedIsBlank else { return }
        let op = PresetSwitchGate.Operation(sessionID: id, endpoint: endpoint, generation: generation, epoch: selectionEpoch, attempt: carrier.currentRefreshToken())
        activePresetSwitch = op
        let result = await presetSwitch.select(op, presetID: presetID,
            onBusy: { [weak self] in self?.switchingPreset = $0 },
            rpc: { [weak self] preset in
                guard let api = self?.api else { throw HarnessError(message: "The connection dropped before the preset switch was confirmed.") }
                return try await api.rpc("agentPresets/select", args: ["agentId": .string(op.sessionID), "agentPreset": .string(preset)])
            },
            live: { [weak self] op in self?.isLivePresetSwitch(op) ?? false },
            onAccepted: { [weak self] accepted in
                guard let self, self.activePresetSwitch === op else { return }
                // The accepted id is the Host's answer; the projection it
                // names arrives with the list refresh below. One refresh: the
                // accepted preset, the blank fact and the model selection all
                // ride the same session/list - no second, duplicate pull.
                await self.refresh()
                guard self.activePresetSwitch === op, self.isLivePresetSwitch(op) else { return }
                // The composition can change the model groups: refresh the
                // model/effort catalog the picker renders from.
                if let api = self.api {
                    do {
                        let updated = try await api.rpc("session/modelCatalog", args: [:])
                        guard self.activePresetSwitch === op, self.isLivePresetSwitch(op) else { return }
                        self.catalog = updated
                    } catch {
                        // The switch itself landed: a catalog that cannot be
                        // refreshed keeps the old one rather than unwinding.
                        guard self.activePresetSwitch === op else { return }
                    }
                }
                guard self.activePresetSwitch === op, self.isLivePresetSwitch(op) else { return }
                // Point the conversation stream at the new composition. The
                // command catalog needs no pull of its own: the Host's own
                // agent-preset/selected event invalidates it (the existing
                // CommandCatalog path), so nothing refreshes twice.
                do { try await self.followSelected() } catch {}
            },
            onRejected: { [weak self] error in
                guard let self, self.activePresetSwitch === op else { return }
                // The rejection is this switch's only visible effect: the
                // accepted projection is server-owned and is never written
                // from the client side, so it keeps the last accepted preset.
                self.error = error.localizedDescription
            })
        // The post-response effects are owned by the operation that still
        // holds the seat. The gate already re-checked liveness at the
        // response boundary; this is the store's own seat check for the
        // effects that run here, after the gate returned.
        guard activePresetSwitch === op else { return }
        switch result.outcome {
        case .accepted:
            // The refresh, the catalog and the follow already ran inside
            // onAccepted - each under its own ownership re-check.
            break
        case .rejected:
            // The error is already published by onRejected.
            break
        case .stale:
            // The seat moved on: nothing is written; the newer switch - or
            // the invalidation - owns the state now.
            break
        }
        // Release the store-owned seat exactly once, only if this operation
        // still holds it: the invalidation paths (a newer selection, a
        // disconnect) already cleared it, and a switch that settled without
        // the seat releases nothing - never a seat that is not its own. The
        // blank window must outlive a settled switch: the host keeps
        // sessionListMetadata.blank true while the turn has not started, so
        // the same session can switch again - accepted or after a refusal -
        // before its first prompt.
        if activePresetSwitch === op { activePresetSwitch = nil }
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
    /// B3: whether a pending preset switch can still land: the session,
    /// endpoint, connection generation and selection epoch it was sent on all
    /// still hold, and the carrier still accepts the attempt it rode on.
    private func isLivePresetSwitch(_ op: PresetSwitchGate.Operation) -> Bool {
        guard connected, api != nil else { return false }
        return op.sessionID == selectedID
            && op.endpoint == endpoint
            && op.generation == generation
            && op.epoch == selectionEpoch
            && carrier.accepts(op.attempt)
    }

    /// C1: freeze one permission preset selection of the selected session and
    /// dispatch it through the control pipeline. The click is the only moment
    /// the live store is read: the projection, the catalog and the connection
    /// identity are frozen into the operation, and every decision after the
    /// suspension re-checks the freeze, never the live session list.
    func selectPermission(_ value: String) async {
        await dispatchControl(.permission(value: value))
    }

    /// C1: freeze the plan-mode toggle of the selected session and dispatch
    /// it. A pending projection is the transition in flight: the click asks
    /// for nothing, and no RPC leaves while one is outstanding.
    func togglePlan() async {
        await dispatchControl(.plan)
    }

    /// The frozen dispatch of one control click: the store's own seat, the
    /// frozen context, the commands/execute leg and the ownership re-check
    /// after the suspension. A second click before the first settled is a
    /// no-op, like the preset switch - never a supersede.
    private func dispatchControl(_ intent: SessionControlIntent) async {
        guard !usesNativeHarness, connected, api != nil, let id = selectedID else { return }
        // C1: the command boundary is one seat, in both directions. A pending
        // control owns it, and a pending preset switch owns it the same way:
        // the second seat is refused, never superseded, so the two can never
        // interleave on the wire.
        guard activeControl == nil, !switchingPreset else { return }
        let context = SessionControlContext(
            sessionID: id, endpoint: endpoint,
            generation: generation, epoch: selectionEpoch,
            attempt: carrier.currentRefreshToken(),
            catalogGeneration: commandDirectory.catalogGeneration,
            presetGeneration: presetRosterPull,
            catalog: commandDirectory.snapshot(id),
            permissions: projectionStores[id]?.permissions,
            plan: projectionStores[id]?.plan)
        guard let op = controls.begin(intent, context) else { return }
        activeControl = op
        controlOutcome = nil
        let outcome = await controls.dispatch(op,
            live: { [weak self] op in self?.isLiveControl(op) ?? false },
            rpc: { [weak self] line in
                guard let api = self?.api else {
                    throw HarnessError(message: "The connection dropped before the control switch was confirmed.")
                }
                return try await api.rpc("commands/execute",
                                         args: commandExecuteArguments(agentId: op.context.sessionID, line: line, submittedAttachments: []))
            })
        // The post-response effects are owned by the operation that still
        // holds the seat: a late answer of a dropped action writes no
        // outcome and no error over the session that replaced it.
        guard activeControl === op else { return }
        switch outcome {
        case .routedToFullAccess:
            // C2: the escalation is a question, not a line. The dispatch
            // settled the decision without a wire and released the controls
            // seat; the chip keeps the store seat while the shared question
            // is open - the confirmation, not the dispatch, is the action's
            // continuation.
            guard requestFullAccess(.control(op)) else {
                // The gate already shows another question: this click is
                // refused with the routing outcome it published, and the seat
                // it took is freed - never held for a question that will not
                // open.
                controlOutcome = outcome
                if activeControl === op { activeControl = nil }
                return
            }
            controlOutcome = outcome
            return
        case .stale:
            // The identity moved: the answer is discarded, and neither the
            // outcome nor the error is written over the session that
            // replaced it.
            break
        case .failed(let message):
            // The failure is the lineage's visible error, owned by the
            // operation that wrote it: a later settled control clears
            // exactly this message, and the switch / disconnect hooks retire
            // it with the lineage.
            controlOutcome = outcome
            error = message
            controlError = (operation: op, message: message)
        default:
            // A settled non-failure outlives a failure the lineage wrote: it
            // clears the control-owned error if, and only if, the store still
            // shows exactly that message - never an error another subsystem
            // published over it.
            if let owned = controlError, error == owned.message {
                error = nil
                controlError = nil
            }
            controlOutcome = outcome
        }
        if activeControl === op { activeControl = nil }
    }

    /// C1: whether a pending control action is still on the live session and
    /// connection it was frozen from: the session, endpoint, connection
    /// generation and selection epoch all match, the carrier still accepts
    /// the attempt it rode on, and the capability facts it read - the command
    /// catalog generation and the preset roster generation - are still the
    /// live ones. A rotated generation or a re-pulled roster stales the
    /// action instead of landing its answer on the new identity. The frozen
    /// projection must still be live too, in the exact shape the click was
    /// decided against: a projection that moved away from the click's own
    /// re-emit - or lost the capability - no longer owns the answer.
    private func isLiveControl(_ op: SessionControlOperation) -> Bool {
        guard connected, api != nil else { return false }
        guard op.context.sessionID == selectedID
            && op.context.endpoint == endpoint
            && op.context.generation == generation
            && op.context.epoch == selectionEpoch
            && carrier.accepts(op.context.attempt)
            && commandDirectory.catalogGeneration == op.context.catalogGeneration
            && presetRosterPull == op.context.presetGeneration else { return false }
        // The frozen projection is part of the freeze. The one move that
        // keeps the action live is the click's own success: the server
        // applies the switch and republishes the projection before the ack,
        // so the live value equals the value the click asked for - the
        // normal projection-before-RPC ordering, not a move under the click.
        guard let live = projectionStores[op.context.sessionID] else { return false }
        switch op.intent {
        case .permission(let value):
            guard let frozen = op.context.permissions, let current = live.permissions
            else { return false }
            guard current.options == frozen.options else { return false }
            return current.currentValue == frozen.currentValue || current.currentValue == value
        case .plan:
            guard let frozen = op.context.plan, let current = live.plan else { return false }
            // Unchanged, the click's own transition in flight, or the target
            // already reached: anything else moved the mode without this
            // click. The frozen pending is false - a pending projection never
            // dispatches a line.
            return (current.active, current.pending) == (frozen.active, false)
                || (current.active, current.pending) == (frozen.active, true)
                || (current.active, current.pending) == (!frozen.active, false)
        }
    }
    /// The store's live session and connection as one value: what a pending
    /// action is checked against when its question is answered.
    var liveConnectionIdentity: LiveConnectionIdentity {
        LiveConnectionIdentity(sessionID: selectedID, endpoint: endpoint, catalogGeneration: commandDirectory.catalogGeneration)
    }

    /// Ask the user to confirm one access escalation. The pending question is
    /// bound to the action's own snapshot, so the composer can keep being edited
    /// while it is on screen, and a second request while one is unanswered is
    /// refused instead of replacing it. The refusal is reported to the caller:
    /// a control chip that is refused must free the seat it took.
    @discardableResult
    func requestFullAccess(_ target: FullAccessGate.Target) -> Bool {
        guard let pending = fullAccessGate.request(target) else { return false }
        accessConfirmation = pending
        return true
    }

    /// The user declined the pending escalation: nothing is sent, and the
    /// composer keeps exactly the draft and attachments it held.
    func cancelFullAccess(_ id: UUID) {
        guard accessConfirmation?.id == id, fullAccessGate.cancel(id: id) else { return }
        // The control question's action seat dies with its question: the next
        // chip click takes a fresh freeze, never a chair already occupied.
        if case .control(let op)? = accessConfirmation?.target, activeControl === op {
            activeControl = nil
            controlOutcome = nil
        }
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
        // The target is read before the question is withdrawn: a rejected
        // answer still owes its control action the seat and the outcome it
        // held.
        let target = accessConfirmation!.target
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
        }, control: { [weak self] op in
            guard let self else { return }
            await self.confirmControlEscalation(op)
        })
        // The answer found no action to run - the session or the connection moved
        // under the question, or another send owns the store - so nothing was
        // enabled or sent. Saying so beats a dialog that closes as if it had
        // worked.
        if outcome == .rejected {
            // A refused control answer still owes its action the seat and the
            // routing outcome it published when the question opened.
            if case .control(let op) = target, activeControl === op {
                activeControl = nil
                controlOutcome = nil
            }
            error = "Full access was not enabled: the session or the connection changed. Send it again."
        }
    }

    /// The frozen `/permission` leg behind a confirmed control question. It
    /// re-checks the full freeze before the wire - the same liveness the line
    /// dispatch re-checks at its answer boundary - and sends exactly the line
    /// the click froze: the session it named, and no draft, no images, no
    /// cleanup. The composer keeps everything it was editing while the
    /// question was on screen.
    private func confirmControlEscalation(_ op: SessionControlOperation) async {
        guard isLiveControl(op), !submitting, connected, let api = self.api else {
            if activeControl === op { activeControl = nil; controlOutcome = nil }
            return
        }
        submitting = true
        defer { submitting = false }
        do {
            let value = try await api.rpc("commands/execute",
                                          args: commandExecuteArguments(agentId: op.context.sessionID,
                                                                       line: FullAccessPolicy.commandLine,
                                                                       submittedAttachments: []))
            // The answer boundary of the frozen action: a seat a newer action
            // took is not this action's to settle, and an identity that moved
            // under the wire discards the answer instead of landing it.
            guard activeControl === op else { return }
            guard isLiveControl(op) else {
                activeControl = nil
                controlOutcome = nil
                return
            }
            let execution = CommandExecution(value)
            if execution.result.isSuccess {
                if let owned = controlError, error == owned.message {
                    error = nil
                    controlError = nil
                }
                controlOutcome = .sent(line: FullAccessPolicy.commandLine)
            } else {
                let message = value == .null
                    ? SessionControls.unknownCommandMessage(line: FullAccessPolicy.commandLine)
                    : execution.result.isError
                        ? execution.result.text ?? SessionControls.commandFailedMessage(line: FullAccessPolicy.commandLine)
                        : SessionControls.malformedResultMessage(line: FullAccessPolicy.commandLine)
                controlOutcome = .failed(message)
                error = message
                controlError = (operation: op, message: message)
            }
        } catch {
            guard activeControl === op else { return }
            let message = error.localizedDescription
            controlOutcome = .failed(message)
            self.error = message
            controlError = (operation: op, message: message)
        }
        if activeControl === op { activeControl = nil }
    }

    /// A control question is stale when the capability facts it was frozen
    /// from move: a newer agentPresets/list pull (the create sheet re-asked
    /// the roster), or a baseline fold that dropped the `permissions`
    /// projection the click read. The question is retired with the seat it
    /// held - nothing else of the store is touched, and a late confirm of the
    /// retired id finds no question to answer.
    private func retireStaleControlQuestion() {
        guard case .control(let op)? = accessConfirmation?.target else { return }
        let rosterMoved = presetRosterPull != op.context.presetGeneration
        let capabilityGone = projectionStores[op.context.sessionID]?.permissions == nil
        guard rosterMoved || capabilityGone else { return }
        confirmationLifecycle.reset()
        accessConfirmation = nil
        if activeControl === op { activeControl = nil }
        controlOutcome = nil
    }

    /// Drop an unanswered escalation question without a decision. Its action
    /// names one session and one connection generation, and neither survives the
    /// question: after a switch, a reconnect or a teardown there is nothing left
    /// for the user to be answering. A control question carries its action's
    /// seat with it: the drop releases the seat and the routing outcome the
    /// question published.
    private func clearAccessConfirmation() {
        if case .control(let op)? = accessConfirmation?.target {
            if activeControl === op { activeControl = nil }
            controlOutcome = nil
        }
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
            connection.onFailure = { [weak self] message in self?.nativeConnectionFailed(message) }
            connection.connect(url: url, token: token)
        } catch { connecting = false; self.error = error.localizedDescription }
    }
    /// The production path for a live connection failure: the visible state
    /// is cleared, and - before the reconnect decision - the in-flight
    /// create loses its seat, so a create suspended on the host's open
    /// decision is decided by the failure itself. That matters because the
    /// reconnect is not guaranteed to run: a detached workspace returns
    /// early, and a cancelled reconnect task never reaches the store's
    /// disconnect that would otherwise resolve the wait. A reconnect that
    /// does run re-enters through connectNative's disconnect, where the
    /// seat is already lost and the wait already decided - exactly once.
    func nativeConnectionFailed(_ message: String) {
        connected = false; connecting = false; loadingHistory = false
        nativeReady = false; nativeSubmission = nil; interactions = []
        createSeat.invalidate()
        resumePendingOpenDecision(.lost)
        error = message
        guard !workspaceDetached else { return }
        nativeRetry = min(4, nativeRetry + 1)
        let delay = min(10, 1 << (nativeRetry - 1))
        nativeReconnect = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.connect()
        }
    }
    private func nativeSession(_ info: NativeSessionInfo) -> HarnessSession {
        HarnessSession(raw: .object(["sessionId": .string(info.id), "cwd": .string(info.workspace),
            "running": .bool(info.running), "updatedAt": .number(info.updatedAt * 1000),
            "projections": .object(["values": .object(["title": .string(info.title)])])]))
    }
    /// The production entry point for every host event: the connection's
    /// callback and the checks drive the store through this same path.
    func receiveNative(_ event: NativeEvent) {
        // A create's open may still be awaiting the host's decision: the
        // host's answer to that open - opened, the rejection, synced, the
        // history replay - can land before the send confirmation returns,
        // while the selection still names the prior session. Park the
        // decision frames in their own slots and the history in a bounded
        // window; a lost seat lets the frame fall through to the gate.
        if var pending = pendingNativeOpen, event.session == pending.sessionID,
           createSeat.stillOwns(pending.operation) {
            switch event.op {
            case "opened":
                if pending.opened == nil { pending.opened = event }
                pendingNativeOpen = pending
                resumePendingOpenDecision(.opened)
            case "error":
                // A session-scoped error is the host's decision on this
                // open: park it and publish it while the seat still holds.
                pending.rejection = event
                if let text = event.text { self.error = text }
                pendingNativeOpen = pending
                if pending.opened == nil { resumePendingOpenDecision(.rejected) }
            case "synced":
                // The terminal synced is a decision frame: the load can
                // finish only when it is parked, whatever overflow hit the
                // history before it.
                pending.terminalSynced = event
                pendingNativeOpen = pending
            default:
                // History: a bounded window; an overflow drops the oldest
                // frame and marks the truncation the commit must surface.
                if pending.history.count < Self.pendingNativeOpenLimit {
                    pending.history.append(event)
                } else {
                    pending.history.removeFirst()
                    pending.history.append(event)
                    pending.historyDropped = true
                }
                pendingNativeOpen = pending
            }
            return
        }
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
