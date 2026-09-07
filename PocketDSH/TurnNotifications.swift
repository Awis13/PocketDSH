import SwiftUI
import BackgroundTasks
import UserNotifications
import OSLog

@MainActor
final class TurnNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = TurnNotifications()
    private let experimentAvailable = false
    @Published var enabled = false
    @Published private(set) var status = "Off"
    @Published private(set) var watching = false
    @Published var destination: [String: String]?
    private var heartbeat: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var generation = UUID()
    private var schedulerID: String?
    private var completeTask: ((Bool) -> Void)?
    private var updateTask: ((Int) -> Void)?
    private var eventCount = 0
    private var lastPong = Date.distantPast
    private let logger = Logger(subsystem: "dev.awis.PocketDSH", category: "TurnNotifications")
    override init() {
        super.init()
        // The continued-processing experiment is withdrawn from the daily client.
        UserDefaults.standard.set(false, forKey: "harness.turnNotifications")
        BGTaskScheduler.shared.cancelAllTaskRequests()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().delegate = self
        status = enabled ? "Ready for your next task" : "Off"
    }
    func setEnabled(_ value: Bool) async {
        guard experimentAvailable else { return }
        guard value else {
            enabled = false; UserDefaults.standard.set(false, forKey: "harness.turnNotifications")
            stop("Off"); return
        }
        guard #available(iOS 26.0, *) else { status = "Requires iOS 26 or later"; return }
        do {
            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else {
                status = "Allow notifications in iPhone Settings"; return
            }
            enabled = true; UserDefaults.standard.set(true, forKey: "harness.turnNotifications")
            status = "Ready for your next task"
        } catch { status = "Notification permission failed: \(error.localizedDescription)" }
    }
    private func record(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let url = URL.documentsDirectory.appending(path: "notification-diagnostics.txt")
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += line
        try? String(text.suffix(24000)).write(to: url, atomically: true, encoding: .utf8)
    }
    func stop(_ message: String, success: Bool = false) {
        generation = UUID(); heartbeat?.cancel(); heartbeat = nil; worker?.cancel(); worker = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        if !success, let id = schedulerID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id) }
        schedulerID = nil; completeTask?(success); completeTask = nil; updateTask = nil
        watching = false; status = message
        record("Observer stopped: " + message)
    }
    func start(api: HarnessAPI, endpoint: String, session: String, requestID: String, title: String, diagnostic: Bool = false) {
        #if !targetEnvironment(macCatalyst)
        guard experimentAvailable, enabled else { return }
        guard #available(iOS 26.0, *) else { return }
        stop("Starting background watch…")
        let token = generation
        let started = Date()
        let duration = diagnostic ? 75 : 1800
        let id = "dev.awis.PocketDSH.turn." + UUID().uuidString
        schedulerID = id; watching = true; eventCount = 0; lastPong = .distantPast
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.stop("Background watch ended. Open the task to check its result.")
                    }
                }
                // This measures a bounded monitoring window, not the agent's unknown completion percentage.
                task.progress.totalUnitCount = Int64(duration)
                self.completeTask = { success in task.setTaskCompleted(success: success) }
                self.updateTask = { elapsed in
                    task.progress.completedUnitCount = Int64(min(duration - 1, max(1, elapsed)))
                    task.updateTitle(diagnostic ? "Testing background connection" : "Watching your task",
                                     subtitle: "\(elapsed / 60):\(String(format: "%02d", elapsed % 60)) elapsed · \(diagnostic ? "75 sec check" : "30 min watch")")
                }
                self.status = "Watching in background"
                self.record("Continued task granted")
                self.updateTask?(Int(Date().timeIntervalSince(started)))
            }
        }
        guard registered else { stop("iOS could not register background watch"); return }
        do {
            let request = BGContinuedProcessingTaskRequest(identifier: id, title: diagnostic ? "Testing background connection" : "Watching your task", subtitle: String(title.prefix(80)))
            request.strategy = .fail
            try BGTaskScheduler.shared.submit(request)
            record("Continued task submitted; monitoring budget \(duration)s")
        } catch { stop("Background watch unavailable: \(error.localizedDescription)"); return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.generation == token, !Task.isCancelled else { return }
                let elapsed = Int(Date().timeIntervalSince(started))
                if elapsed >= duration {
                    if diagnostic && Date().timeIntervalSince(self.lastPong) < 12 {
                        await self.finish(reason: "diagnostic", endpoint: endpoint, session: session, title: "Background connection verified after 75 seconds", requestID: requestID, token: token)
                    } else { self.stop(diagnostic ? "Connection check failed: server did not respond recently" : "30-minute watch ended. Open the task to continue watching.") }
                    return
                }
                guard let socket = self.socket else { continue }
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        socket.sendPing { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.lastPong = Date()
                    self.updateTask?(elapsed)
                    self.record("Server ping received at \(elapsed)s; stream updates \(self.eventCount); app state \(UIApplication.shared.applicationState.rawValue)")
                } catch {
                    if self.generation == token { self.record("Server ping failed; reconnecting") }
                }
            }
        }
        worker = Task { [weak self] in
            guard let self else { return }
            var state = TurnNotificationState(requestID: requestID)
            for attempt in 0..<5 {
                guard !Task.isCancelled, self.generation == token else { return }
                do {
                    let socket = api.socket(); self.socket = socket
                    let frame: JSON = .object(["type": .string("open"), "streamId": .string("turn-watch"), "endpoint": .string("session/follow"), "payload": .object(["args": .object(["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(session)]), "maxMessages": .number(100)])])])])
                    try await socket.send(.string(String(decoding: JSONEncoder().encode(frame), as: UTF8.self)))
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard self.generation == token else { return }
                        let data: Data
                        switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                        let frame = try JSONDecoder().decode(JSON.self, from: data)
                        if frame["type"].string == "error" { throw HarnessError(message: "Task stream unavailable") }
                        guard frame["type"].string == "item" else { continue }
                        let value = frame["value"]
                        let events = value["type"].string == "snapshot" ? value["records"].array.map { $0["event"] } : value["type"].string == "event" ? [value["event"]] : []
                        for event in events {
                            let fresh = event["seq"].int > state.cursor
                            let result = state.consume(event)
                            if fresh && state.accepted {
                                self.eventCount += 1
                            }
                            if let result {
                                await self.finish(reason: result, endpoint: endpoint, session: session, title: title, requestID: requestID, token: token)
                                return
                            }
                            if fresh && state.accepted && event["type"].string == "approval/asked" {
                                await self.finish(reason: "blocked", endpoint: endpoint, session: session, title: title, requestID: requestID, token: token); return
                            }
                        }
                    }
                } catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.socket?.cancel(with: .goingAway, reason: nil)
                    self.record("Observer connection interrupted, attempt \(attempt)")
                    if attempt < 4 { try? await Task.sleep(for: .seconds(min(8, 1 << attempt))) }
                }
            }
            if self.generation == token { self.stop("Background connection lost. Open the task to check its result.") }
        }
        #endif
    }
    private func finish(reason: String, endpoint: String, session: String, title: String, requestID: String, token: UUID) async {
        guard generation == token else { return }
        record("Observer outcome: " + reason)
        let content = UNMutableNotificationContent()
        content.title = reason == "diagnostic" ? "Background check finished" : reason == "completed" ? "Task finished" : reason == "blocked" ? "Your agent needs you" : "Task stopped"
        content.body = String(title.prefix(180)); content.sound = .default
        content.userInfo = ["endpoint": endpoint, "session": session]
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "turn-" + requestID, content: content, trigger: nil))
            guard generation == token else { return }
            stop("Notification sent", success: true)
        } catch { if generation == token { stop("Could not show notification: \(error.localizedDescription)") } }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let endpoint = info["endpoint"] as? String, let session = info["session"] as? String else { return }
        await MainActor.run { self.destination = ["endpoint": endpoint, "session": session] }
    }
}

struct TurnNotificationSettings: View {
    @ObservedObject private var notifications = TurnNotifications.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PocketStore
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Notify when a task finishes", isOn: Binding(get: { notifications.enabled }, set: { value in Task { await notifications.setEnabled(value) } }))
                    Text(notifications.status).font(.footnote).accessibilityIdentifier("notificationStatus")
                } footer: {
                    Text("Experimental · iOS 26. Starts when you send a new task to an idle agent. One task at a time, up to 30 minutes. The system indicator measures the watch time, not agent completion. iOS may stop background monitoring; force-quitting the app stops it. Your agent keeps working on your Mac.")
                }
                Button("Run 75-second connection check") { store.checkBackgroundNotifications() }
                    .disabled(!notifications.enabled || !store.connected || notifications.watching)
                if notifications.watching { Button("Stop watching", role: .destructive) { notifications.stop("Watch stopped") } }
                Button("Open iPhone Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }.navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
