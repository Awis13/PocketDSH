import Foundation
import Combine

@MainActor
final class PocketStore: ObservableObject {
    @Published var endpoint = UserDefaults.standard.string(forKey: "harness.endpoint") ?? ""
    @Published var connected = false
    @Published var connecting = false
    @Published var error: String?
    @Published var sessions: [HarnessSession] = []
    @Published var workspaces: [HarnessWorkspace] = []
    @Published var archived = Set<String>()
    @Published var readingMode = false
    var openDefaultTaskWhenConnected = false
    @Published var voiceRecording = false
    @Published var selectedID: String?
    @Published var composerFocusRequest: UUID?
    private var newlyCreatedSession: String?
    func focusNewSessionComposer() {
        guard let id = newlyCreatedSession else { return }
        newlyCreatedSession = nil
        if selectedID == id { composerFocusRequest = UUID() }
    }
    @Published var rows: [TranscriptRow] = []
    @Published var interactions: [Interaction] = []
    @Published var queues: [String: JSON] = [:]
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
    private var api: HarnessAPI?
    private var socket: URLSessionWebSocketTask?
    private var connectionTask: Task<Void, Never>?
    private var generation = UUID()
    private var followID = ""
    private var clientID = ""
    private var drafts: [String: String] = [:]
    private var pendingRequest: (id: String, text: String, session: String, imageIDs: [UUID])?
    private var projectionSeq: [String: Int] = [:]
    var selected: HarnessSession? { sessions.first { $0.id == selectedID } }
    var running: Bool { selected?.running ?? false }
    var liveReasoning: TranscriptRow? {
        guard connected, running, let latest = rows.last(where: { $0.kind != .notice }),
              latest.kind == .reasoning, !latest.complete, !latest.text.isEmpty else { return nil }
        return latest
    }
    var visibleSessions: [HarnessSession] { sessions.filter { !archived.contains($0.id) && $0.raw["origin"].string != "subagent" }.sorted { $0.date > $1.date } }
    var currentInteractions: [Interaction] { interactions.filter { $0.sessionID == selectedID } }
    var currentQueue: [JSON] { queues[selectedID ?? ""]?.array ?? [] }
    var modelLabel: String { model["model"].string.isEmpty ? "Host model" : model["model"].string }

    init() {
        imageCache.totalCostLimit = 24 * 1024 * 1024
        if let data = try? Data(contentsOf: imageDraftFile), let saved = try? PropertyListDecoder().decode([String: [OutgoingImage]].self, from: data) { imageDrafts = saved }
        drafts = UserDefaults.standard.dictionary(forKey: "harness.drafts." + endpoint) as? [String: String] ?? [:]
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
        if ProcessInfo.processInfo.environment["DSH_DEMO"] == "1" { loadDemo(); return }
        #endif
        guard !(input ?? endpoint).isEmpty else { return }
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
            UserDefaults.standard.set(endpoint, forKey: "harness.endpoint")
            sessions = result["items"].array.map { HarnessSession(raw: $0) }
            catalog = loadedCatalog
            startCarrier()
        } catch { if attempt == generation { self.error = error.localizedDescription; connecting = false; connectionDiagnostic("connect-failed", error: error) } }
    }
    func disconnect() {
        generation = UUID(); connectionTask?.cancel(); connectionTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        connected = false; connecting = false; loadingHistory = false; interactions = []; clientID = ""
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
                    self.connecting = true; self.interactions = []; self.queues = [:]; self.projectionSeq = [:]
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
                try await open("workspace/follow", id: "workspaces")
                try await open("session/control", id: "control")
                // Refresh the list after readiness; later event frames stay buffered in the socket.
                await refresh()
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
                for (sid, p) in value["value"]["projections"].object { applyProjection(sid, p: p) }
            } else if type == "queue" { queues[value["sessionId"].string] = value["items"] }
            else if type == "projection" {
                let sid = value["sessionId"].string, key = value["key"].string, seq = value["seq"].int
                let stamp = sid + "/" + key
                if seq >= (projectionSeq[stamp] ?? -1) {
                    projectionSeq[stamp] = seq
                    patchProjection(sid, key: key, value: value["value"])
                }
            }
            reconcilePending()
        } else if id == followID {
            if type == "snapshot" {
                transcript.replace(value["records"].array, cursor: value["cursor"].int)
                hasMore = value["hasMore"].bool; loadingHistory = false
                if let sid = selectedID { applyProjection(sid, p: value["projections"]) }
            } else if type == "event" {
                guard transcript.append(value["event"]) else { try await followSelected(); return }
            }
            rows = transcript.rows; reconcilePending()
        }
    }
    private func applyProjection(_ sid: String, p: JSON) {
        for (key, value) in p["values"].object {
            let stamp = sid + "/" + key, seq = p["asOfSeq"].int
            if seq >= (projectionSeq[stamp] ?? -1) { projectionSeq[stamp] = seq; patchProjection(sid, key: key, value: value) }
        }
    }
    private func patchProjection(_ sid: String, key: String, value: JSON) {
        if let i = sessions.firstIndex(where: { $0.id == sid }) {
            var raw = sessions[i].raw.object, p = raw["projections"]?.object ?? [:], values = p["values"]?.object ?? [:]
            values[key] = value; p["values"] = .object(values); raw["projections"] = .object(p); sessions[i].raw = .object(raw)
        }
        if sid == selectedID && key == "imageLimits" { imageLimits = ImageLimits(value) }
        if sid == selectedID && key == "modelSelection" { model = value["next"] == .null ? catalog["default"] : value["next"] }
    }
    private func updateSession(_ id: String, key: String, value: JSON) {
        if let i = sessions.firstIndex(where: { $0.id == id }) { var raw = sessions[i].raw.object; raw[key] = value; sessions[i].raw = .object(raw) }
    }
    func refresh() async {
        guard let api else { return }
        do { sessions = try await api.rpc("session/list", args: ["_request": .object([:])])["items"].array.map { HarnessSession(raw: $0) } }
        catch { self.error = error.localizedDescription }
    }
    func select(_ id: String?) async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DSH_DEMO"] == "1" { loadDemo(); selectedID = id; return }
        #endif
        if let old = selectedID { drafts[old] = draft }
        drafts = UserDefaults.standard.dictionary(forKey: "harness.drafts." + endpoint) as? [String: String] ?? drafts
        if let data = try? Data(contentsOf: imageDraftFile), let saved = try? PropertyListDecoder().decode([String: [OutgoingImage]].self, from: data) { imageDrafts = saved }
        readingMode = false
        selectedID = id; images = imageDrafts[imageDraftKey] ?? []; imageLimits = ImageLimits(); draft = drafts[id ?? ""] ?? ""; rows = []; transcript = Transcript(); hasMore = false
        pendingText = pendingRequest?.session == id ? (pendingRequest?.text.isEmpty == true ? "Image" : pendingRequest?.text) : nil
        model = selected?.raw["projections"]["values"]["modelSelection"]["next"] ?? .null
        if model == .null { model = catalog["default"] }
        guard connected else { return }
        do { try await followSelected() } catch { self.error = error.localizedDescription; loadingHistory = false }
    }
    private func followSelected() async throws {
        if !followID.isEmpty { try await sendFrame(.object(["type": .string("cancel"), "streamId": .string(followID)])) }
        followID = UUID().uuidString
        guard let id = selectedID else { return }
        loadingHistory = true
        try await open("session/follow", id: followID, args: ["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(id)]), "maxMessages": .number(50)])])
    }
    func loadOlder() async {
        guard let api, let id = selectedID, let beforeSeq = transcript.firstSeq, !loadingHistory else { return }
        loadingHistory = true; let stream = followID
        defer { if stream == followID { loadingHistory = false } }
        do {
            let page = try await api.rpc("session/page", args: ["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(id)]), "throughSeq": .number(Double(transcript.cursor)), "beforeSeq": .number(Double(beforeSeq)), "maxMessages": .number(50)])])
            guard stream == followID else { return }
            transcript.prepend(page["records"].array); rows = transcript.rows; hasMore = page["hasMore"].bool
        } catch { if stream == followID { self.error = error.localizedDescription } }
    }
    func createDefaultTask() async {
        // Omitting workspaceId uses the Harness server's working directory.
        await create(workspaceID: nil)
        focusNewSessionComposer()
    }
    func create(workspaceID: String?) async {
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
    func cancel() async { await command("session/cancel", request: ["sessionId": .string(selectedID ?? "")]) }
    func selectModel(provider: String, model: String) async {
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
            let value = try await api.rpc("commands/execute", args: ["agentId": .string(item.sessionID),
                "line": .string("/permission danger-full-access"), "images": .array([])])
            guard value["result"]["kind"].string == "success" else {
                throw HarnessError(message: value["result"]["text"].string.isEmpty ? "Full access was not confirmed by Harness." : value["result"]["text"].string)
            }
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func answer(_ item: Interaction, value: JSON) async {
        guard let api, connected, item.clientID == clientID, interactions.contains(where: { $0.id == item.id }) else { return }
        do {
            _ = try await api.rpc("$events/result", args: ["clientId": .string(clientID), "eventId": .string(item.id), "outcome": .object(["kind": .string("result"), "value": value])])
            interactions.removeAll { $0.id == item.id }
        } catch { self.error = error.localizedDescription }
    }
}
