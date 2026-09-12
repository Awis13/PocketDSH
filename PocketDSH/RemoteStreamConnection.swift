import Foundation

/// The two operations the stream coordinator drives on one Remote carrier
/// socket. `URLSessionWebSocketTask` is the app's implementation; the offline
/// checks substitute a fake, which is what makes the interleavings below
/// deterministic without a network.
protocol RemoteStreamTransport: AnyObject {
    /// Send one frame as a text message - the only encoding the mux accepts.
    func sendFrame(_ frame: JSON) async throws
    /// Send an application-level ping and await its pong.
    func ping() async throws
}

/// One frame this client sends on a Remote carrier. The wire shape lives next
/// to the identity rules that decide when the frame may be sent at all.
enum RemoteStreamFrame: Equatable {
    /// Retire one stream ID on the gateway. The gateway aborts the pump
    /// synchronously but drops the ID only when the pump finishes, so the ID
    /// must never be reopened.
    case cancel(streamId: String)
    /// Open one logical stream under a freshly minted ID.
    case open(streamId: String, endpoint: String, args: [String: JSON])

    var json: JSON {
        switch self {
        case .cancel(let streamId):
            return .object(["type": .string("cancel"), "streamId": .string(streamId)])
        case .open(let streamId, let endpoint, let args):
            return .object([
                "type": .string("open"), "streamId": .string(streamId), "endpoint": .string(endpoint),
                "payload": .object(["args": .object(args)])
            ])
        }
    }
}

/// The identity rules of one Remote carrier: which socket attempt is live,
/// which stream ID belongs to which logical stream, and which of the work the
/// carrier started - the 15-second ping, the HTTP refresh - may still report.
///
/// `PocketStore` owns the socket and the UI, so every decision that depends on
/// *whose* frame, *whose* ping or *whose* refresh result this is, is taken
/// here, in a value the offline gates compile and drive with a fake transport:
///
/// - **One attempt per socket.** `beginAttempt` rotates the identity, drops
///   every stream ID the previous attempt held and cancels the ping and
///   refresh work that attempt owned, so nothing the old socket started can
///   reach the new one or the UI.
/// - **Retire before any `await`.** `subscribe` and `cancel` retire the old ID
///   synchronously; `admit` is the only door for incoming frames and refuses
///   every frame - data, error or end - whose ID is not a live one.
/// - **One winner per replacement.** `subscribe` re-checks its attempt and its
///   own ID after the cancel frame is on the wire and before the open frame is
///   sent, so two overlapping replacements open exactly one stream, and a
///   teardown during the cancel opens none at all.
/// - **One retry owner.** `run` is the only loop that decides to reconnect and
///   the only one that reports the final "not connecting" state; a failed ping
///   or a failed stream is reported through its callbacks and never acted on
///   here.
@MainActor
final class RemoteStreamConnection {
    typealias Kind = HarnessStreamSet.Kind

    /// One socket attempt of one carrier: a fresh identity and a clean slate.
    struct Attempt: Equatable {
        /// 1-based, exactly as the diagnostic records it.
        let index: Int
        let id: UUID
    }

    /// One admitted frame: the live stream it belongs to and the frame itself.
    struct Delivery: Equatable {
        let kind: Kind
        let frame: JSON
    }

    /// The identity of one scheduled refresh.
    struct RefreshToken: Equatable {
        let attempt: Attempt
        let id: UUID
    }

    /// A live stream the server ended. Only the retry loop may bring it back,
    /// and the user sees why the carrier is reconnecting.
    struct StreamEnded: Error, Equatable, LocalizedError {
        let kind: Kind
        var errorDescription: String? { "The DSH " + kind.rawValue + " stream ended unexpectedly." }
    }

    private(set) var streams = HarnessStreamSet()
    private(set) var attempt: Attempt?
    private var pingJob: Task<Void, Never>?
    private var pingToken: UUID?
    private var refreshJobs: [UUID: Task<Void, Never>] = [:]
    /// Set by `stop`: a stopped connection mints no attempt until the next
    /// `run` starts one.
    private var stopped = false

    /// Whether the carrier still owns work for a live attempt.
    var hasOwnedWork: Bool { pingJob != nil || !refreshJobs.isEmpty }

    // MARK: - Attempt lifecycle

    /// Start one socket attempt. The previous attempt loses its identity, its
    /// stream IDs and its ping/refresh work in the same synchronous step.
    @discardableResult
    func beginAttempt(index: Int) -> Attempt? {
        guard !stopped else { return nil }
        discardAttempt()
        let next = Attempt(index: index, id: UUID())
        attempt = next
        return next
    }

    /// End the carrier: a disconnect, or a carrier that is being replaced.
    /// Nothing this connection started may report afterwards, and no attempt
    /// is minted until the next `run`.
    func stop() {
        stopped = true
        discardAttempt()
    }

    private func discardAttempt() {
        attempt = nil
        streams.reset()
        pingJob?.cancel(); pingJob = nil; pingToken = nil
        for job in refreshJobs.values { job.cancel() }
        refreshJobs.removeAll()
    }

    /// Whether one attempt is still the live one. A nil attempt is never
    /// current: a caller that captured nothing has nothing to report.
    func isCurrent(_ attempt: Attempt?) -> Bool {
        guard let attempt, !stopped else { return false }
        return self.attempt == attempt
    }

    /// Whether a refresh token is still the live one.
    func isCurrent(_ token: RefreshToken) -> Bool { isCurrent(token.attempt) }

    /// Whether a refresh may still apply its result. A refresh captured while
    /// no attempt was live belongs to the connection its caller already holds,
    /// so only that caller's own identity can refuse it.
    func accepts(_ token: RefreshToken?) -> Bool {
        guard let token else { return true }
        return isCurrent(token)
    }

    // MARK: - Streams

    /// Open one logical stream on the current attempt: mint its ID, retire the
    /// previous one, cancel that one first and open - unless this attempt
    /// ended or a newer replacement won while the cancel was on the wire.
    ///
    /// Returns the opened ID, or nil when this call was superseded: a
    /// superseded call has already retired its own ID and sends no open, so
    /// the winner is the only stream the server ever sees.
    @discardableResult
    func subscribe(_ kind: Kind, endpoint: String, args: [String: JSON] = [:],
                   on transport: RemoteStreamTransport) async throws -> String? {
        guard let attempt, !stopped else { return nil }
        let replacement = streams.replace(kind)
        // Retire before any suspension: from here on the old ID is not
        // admitted, whatever the server still sends for it.
        if let previous = replacement.previous {
            try await transport.sendFrame(RemoteStreamFrame.cancel(streamId: previous).json)
        }
        guard isCurrent(attempt), streams[kind] == replacement.id else { return nil }
        try await transport.sendFrame(RemoteStreamFrame.open(streamId: replacement.id, endpoint: endpoint, args: args).json)
        return replacement.id
    }

    /// Retire one stream without a replacement - a deselect, or a teardown
    /// that still has a socket to tell. The ID is gone before the cancel is
    /// sent, and no cancel is sent when there is no socket to carry it.
    func cancel(_ kind: Kind, on transport: RemoteStreamTransport?) async throws {
        guard let previous = streams.retire(kind) else { return }
        guard let transport, !stopped, attempt != nil else { return }
        try await transport.sendFrame(RemoteStreamFrame.cancel(streamId: previous).json)
    }

    /// The server ended one live stream: retire its ID, so anything else the
    /// server sends for it is discarded, and let the caller decide what the
    /// end means.
    func end(_ kind: Kind) { streams.retire(kind) }

    /// The store's only door for incoming frames. A frame - data, error or end
    /// alike - whose ID is not a live one is discarded here, before any state
    /// is touched.
    func admit(_ frame: JSON) -> Delivery? {
        guard !stopped, attempt != nil, let kind = streams.kind(for: frame["streamId"].string) else { return nil }
        return Delivery(kind: kind, frame: frame)
    }

    // MARK: - Owned work

    /// Own the carrier's application-level ping. One ping task per attempt: it
    /// is cancelled with the attempt, and a failed ping only reports - it
    /// never cancels the socket, never retries and never touches the UI,
    /// because the reader/retry loop is the only owner of both.
    func startPing(interval: Duration = .seconds(15),
                   sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                   ping: @escaping @MainActor () async throws -> Void,
                   onFailure: @escaping @MainActor (Attempt, Error) -> Void) {
        guard let attempt, !stopped else { return }
        pingJob?.cancel()
        let token = UUID()
        pingToken = token
        pingJob = Task { @MainActor [weak self] in
            defer { if let self, self.pingToken == token { self.pingJob = nil; self.pingToken = nil } }
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard let self, self.isCurrent(attempt) else { return }
                do { try await ping() }
                catch {
                    guard self.isCurrent(attempt) else { return }
                    onFailure(attempt, error)
                    return
                }
            }
        }
    }

    /// A token for a refresh the caller runs itself (a list the user asked
    /// for): it names the attempt live at this moment, so the result is refused
    /// once that attempt is gone. Nil when no attempt is live - the caller is
    /// then bound to the connection identity it captured instead.
    func currentRefreshToken() -> RefreshToken? {
        guard let attempt, !stopped else { return nil }
        return RefreshToken(attempt: attempt, id: UUID())
    }

    /// Run one HTTP refresh outside the carrier's receive loop. The scheduling
    /// call returns at once - the receive loop never awaits it - and the work
    /// belongs to the attempt that scheduled it: it is cancelled with that
    /// attempt, and its token is refused by `isCurrent` once that attempt is
    /// no longer the live one.
    @discardableResult
    func scheduleRefresh(_ body: @escaping @MainActor (RefreshToken) async -> Void) -> RefreshToken? {
        guard let token = currentRefreshToken() else { return nil }
        refreshJobs[token.id] = Task { @MainActor [weak self] in
            await body(token)
            self?.refreshJobs.removeValue(forKey: token.id)
        }
        return token
    }

    // MARK: - Carrier loop

    /// The carrier's attempt loop: the only owner of the retry decision and of
    /// the final "not connecting" report.
    ///
    /// Each attempt gets a fresh identity from `beginAttempt`; `onAttempt` runs
    /// before the body (per-attempt state), `onFailure` only for an attempt
    /// that is still current, and `onFinish` exactly once when every attempt
    /// failed. A body that returns - cancellation, or a connection that was
    /// replaced - ends the loop with no retry and no `onFinish`, because the
    /// carrier that replaced it owns the state from then on.
    func run(attempts: Int = 5,
             backoff: @escaping @MainActor (Int) -> Duration = { .seconds(min(8, 1 << $0)) },
             sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
             body: @escaping @MainActor (Attempt) async throws -> Void,
             onAttempt: @escaping @MainActor (Attempt) -> Void,
             onFailure: @escaping @MainActor (Attempt, Error) -> Void,
             onFinish: @escaping @MainActor () -> Void) async {
        stopped = false
        let limit = max(1, attempts)
        for index in 1...limit {
            guard !Task.isCancelled, !stopped, let attempt = beginAttempt(index: index) else { return }
            onAttempt(attempt)
            do {
                try await body(attempt)
                return
            } catch {
                guard isCurrent(attempt), !Task.isCancelled else { return }
                onFailure(attempt, error)
                guard index < limit else { break }
                do { try await sleep(backoff(index - 1)) } catch { return }
                guard !Task.isCancelled, !stopped else { return }
            }
        }
        onFinish()
    }
}

/// One bounded, sanitized connection-diagnostic record.
///
/// A record may only carry values this app itself produced: the stage, the
/// actual socket close code, the attempt number and the stream kind. An error
/// is reduced to its domain, its code and a redacted message, so the file can
/// never hold a cookie, a launch token, a prompt or a credential-bearing URL.
struct RemoteStreamDiagnostic {
    /// How many records a history keeps. The earlier diagnostic history used
    /// the same depth.
    static let historyLimit = 80
    /// The detail keys a record accepts; every other key is dropped.
    static let detailKeys: Set<String> = ["closeCode", "attempt", "stream"]
    static let messageLimit = 200

    let record: [String: Any]

    init(stage: String, connected: Bool, details: [String: Any] = [:], error: Error? = nil, now: Date = Date()) {
        var value: [String: Any] = ["stage": Self.text(stage, limit: 40), "time": now.description, "connected": connected]
        for (key, raw) in details where Self.detailKeys.contains(key) {
            if let number = raw as? Int { value[key] = number }
            else if let flag = raw as? Bool { value[key] = flag }
            else if let text = raw as? String { value[key] = Self.text(text, limit: 40) }
        }
        if let error {
            let failure = error as NSError
            value["domain"] = Self.text(failure.domain, limit: 60)
            value["code"] = failure.code
            value["message"] = Self.sanitized(failure.localizedDescription)
            // A decode failure's own context is what makes it diagnosable: the
            // coding path is field names and the description is a type
            // mismatch, not payload content.
            if case DecodingError.dataCorrupted(let context) = error { value["decode"] = Self.sanitized(context.debugDescription) }
            if case DecodingError.typeMismatch(_, let context) = error {
                value["decode"] = Self.sanitized(context.debugDescription)
                value["path"] = context.codingPath.map(\.stringValue).joined(separator: ".")
            }
        }
        record = value
    }

    /// Redact what can carry a credential - a `?token=...` launch URL, URL
    /// user-info, a quoted `Cookie`/`Authorization` header - and bound the
    /// result so one record stays small and single-line.
    static func sanitized(_ message: String) -> String {
        var text = message
        for pattern in [#"\?[^\s\"]+"#, #"//[^\s\"/@]+@"#, #"(?i)(cookie|authorization|token|bearer)[=:]\s*\S+"#] {
            text = text.replacingOccurrences(of: pattern, with: "<redacted>", options: .regularExpression)
        }
        return self.text(text, limit: messageLimit)
    }

    /// Append one record to a bounded history: the newest record is kept and
    /// the oldest is dropped past `historyLimit`.
    static func appending(_ record: [String: Any], to history: [[String: Any]]) -> [[String: Any]] {
        Array(history.suffix(historyLimit - 1)) + [record]
    }

    private static func text(_ value: String, limit: Int) -> String {
        let collapsed = value.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit))
    }
}

extension URLSessionWebSocketTask: RemoteStreamTransport {
    func sendFrame(_ frame: JSON) async throws {
        try await send(.string(String(decoding: JSONEncoder().encode(frame), as: UTF8.self)))
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
