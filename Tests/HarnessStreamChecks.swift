import Foundation

/// One recorded carrier socket. The checks drive the production
/// `RemoteStreamConnection` through it: every frame the coordinator sends is
/// recorded here, `gate` lets a check park a send to force an interleaving,
/// and the ping counter proves who pinged whom.
@MainActor
final class FakeRemoteTransport: RemoteStreamTransport {
    private(set) var frames: [JSON] = []
    private(set) var pings = 0
    private var pingFailure: Error?
    /// Called after a frame is recorded; a parked body is an interleaving.
    var gate: ((JSON) async -> Void)?

    var opens: [String] { frames.filter { $0["type"].string == "open" }.map { $0["streamId"].string } }
    var cancels: [String] { frames.filter { $0["type"].string == "cancel" }.map { $0["streamId"].string } }

    func failPings(with error: Error) { pingFailure = error }

    func sendFrame(_ frame: JSON) async throws {
        frames.append(frame)
        if let gate { await gate(frame) }
    }

    func ping() async throws {
        pings += 1
        if let pingFailure { throw pingFailure }
    }
}

/// A one-shot park: `wait()` suspends until `release()` resumes everyone
/// parked. It is how a check holds a send or a refresh open while it drives
/// the other side of the interleaving.
@MainActor
final class Park {
    private var parked = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isParked: Bool { parked > 0 }
    func wait() async {
        parked += 1
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        parked = 0
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// A controllable clock for the 15-second ping: `sleep` returns only when the
/// check ticks, so no check waits on real time.
@MainActor
final class ManualClock {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sleeps = 0
    func sleep(_ duration: Duration) async throws {
        sleeps += 1
        await withCheckedContinuation { waiters.append($0) }
    }
    func tick() {
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@main struct HarnessStreamChecks {
    struct Failure: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func json(_ text: String) -> JSON { try! JSONDecoder().decode(JSON.self, from: Data(text.utf8)) }

    static func item(_ streamId: String, _ value: JSON) -> JSON {
        .object(["type": .string("item"), "streamId": .string(streamId), "value": value])
    }
    static func baseline(_ streamId: String) -> JSON { item(streamId, .object(["type": .string("baseline")])) }
    static func snapshot(_ streamId: String) -> JSON {
        item(streamId, .object(["type": .string("snapshot"), "records": .array([]), "cursor": .number(0)]))
    }
    static func delta(_ streamId: String) -> JSON { item(streamId, .object(["type": .string("changed")])) }
    static func failure(_ streamId: String, _ message: String) -> JSON {
        .object(["type": .string("error"), "streamId": .string(streamId), "error": .object(["message": .string(message)])])
    }
    static func end(_ streamId: String) -> JSON { .object(["type": .string("end"), "streamId": .string(streamId)]) }
    static func conversationArgs(_ sessionId: String) -> [String: JSON] {
        ["request": .object(["address": .object(["kind": .string("session"), "sessionId": .string(sessionId)]), "maxMessages": .number(50)])]
    }

    /// Wait until a background task reaches an expected state. The condition is
    /// polled briefly up to a generous deadline: a fixed number of yields is
    /// not a wait on a loaded machine.
    @MainActor
    static func spin(_ reached: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if reached() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        assert(reached(), "the background work never reached the expected state")
    }

    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    @MainActor
    static func run() async throws {
        try await replacementIdentity()
        // The retire-before-await window runs before the overlap check: a
        // mutant that retires after the cancel send must be caught by the
        // window assertion itself, not only by the interleaving that follows.
        try await deselectIdentity()
        try await overlappingReplacements()
        try await teardownDuringCancel()
        try await staleRefreshAfterReconnect()
        try await delayedRefreshKeepsReceiving()
        try await pingOwnership()
        try await carrierLoopOwnsRetry()
        try await perAttemptCleanSlate()
        try await diagnosticsAreSanitizedAndBounded()
        try await liveProbe()
    }

    /// The ported replacement check, through the production coordinator: every
    /// replacement mints a fresh ID, a retired ID is never admitted again - for
    /// data, error or end - and one logical stream never replaces another.
    @MainActor
    static func replacementIdentity() async throws {
        let transport = FakeRemoteTransport()
        let carrier = RemoteStreamConnection()
        assert(carrier.beginAttempt(index: 1) != nil)
        let events = try await carrier.subscribe(.events, endpoint: "$events", on: transport)
        let control = try await carrier.subscribe(.control, endpoint: "session/control", on: transport)
        let conversation = try await carrier.subscribe(.conversation, endpoint: "session/follow", on: transport)
        assert(transport.frames[0].object.keys.sorted() == ["endpoint", "payload", "streamId", "type"],
               "the gateway validates the open frame's exact keys")
        assert(transport.opens == [events, control, conversation].compactMap { $0 })
        var retired = Set<String>()
        var workspaceOpens: [String] = []
        var live = carrier.streams[.workspaces]
        for _ in 0..<100 {
            let next = try await carrier.subscribe(.workspaces, endpoint: "workspace/follow", on: transport)
            let winner = try unwrapped(next, "a replacement must open")
            if !live.isEmpty { retired.insert(live) }
            live = winner
            workspaceOpens.append(winner)
            assert(!retired.contains(winner), "a replacement never reuses a retired ID")
            assert(carrier.admit(baseline(winner)) != nil, "the live workspace stream is admitted")
            assert(retired.allSatisfy { carrier.admit(delta($0)) == nil }, "late data of a retired stream is discarded")
            assert(retired.allSatisfy { carrier.admit(failure($0, "old")) == nil }, "late errors of a retired stream are discarded")
            assert(retired.allSatisfy { carrier.admit(end($0)) == nil }, "late ends of a retired stream are discarded")
            assert(carrier.streams[.events] == events && carrier.streams[.control] == control && carrier.streams[.conversation] == conversation,
                   "a workspace replacement must not replace another stream")
        }
        assert(Set(transport.opens).count == transport.opens.count, "every open on this socket carries a unique ID")
        assert(transport.cancels == Array(workspaceOpens.dropLast()),
               "every replacement after the first cancels exactly its predecessor")
        assert(transport.cancels.allSatisfy { $0 != events && $0 != control && $0 != conversation },
               "a workspace replacement cancels workspace IDs only")
        for frame in transport.frames where frame["type"].string == "cancel" {
            assert(frame.object.keys.sorted() == ["streamId", "type"],
                   "the gateway requires the cancel frame's exact keys")
        }
        // A disconnected carrier admits nothing, and the next carrier run mints
        // a clean attempt: the previous socket's IDs stay refused.
        carrier.stop()
        assert(carrier.admit(baseline(live)) == nil, "a stopped carrier admits nothing")
        assert(carrier.streams[.events].isEmpty && carrier.streams[.workspaces].isEmpty)
        let closed = try await carrier.subscribe(.events, endpoint: "$events", on: transport)
        assert(closed == nil, "a stopped carrier opens nothing")
        var reconnected: RemoteStreamConnection.Attempt?
        await carrier.run(attempts: 1, sleep: { _ in }, body: { attempt in reconnected = attempt },
                          onAttempt: { _ in }, onFailure: { _, _ in }, onFinish: {})
        _ = try unwrapped(reconnected, "the next carrier run mints an attempt")
        assert(carrier.admit(baseline(live)) == nil, "the previous attempt's stream is stale")
        let reopened = try await carrier.subscribe(.events, endpoint: "$events", on: transport)
        assert(reopened != nil && reopened != events, "the new attempt mints a new event stream ID")
        print("PASS stream replacement: unique IDs, stale data/error/end rejection, independent streams and a clean reconnect")
    }

    /// Two replacements that overlap across the cancel send: the newer one wins
    /// and the older one must not open a second stream for the same logical
    /// stream.
    @MainActor
    static func overlappingReplacements() async throws {
        let transport = FakeRemoteTransport()
        let carrier = RemoteStreamConnection()
        assert(carrier.beginAttempt(index: 1) != nil)
        let first = try unwrapped(try await carrier.subscribe(.workspaces, endpoint: "workspace/follow", on: transport),
                                      "the first workspace stream opens")
        let park = Park()
        transport.gate = { frame in if frame["streamId"].string == first { await park.wait() } }
        let slower = Task { try await carrier.subscribe(.workspaces, endpoint: "workspace/follow", on: transport) }
        await spin { park.isParked }
        let superseded = carrier.streams[.workspaces]
        let winner = try await carrier.subscribe(.workspaces, endpoint: "workspace/follow", on: transport)
        let live = try unwrapped(winner, "the second replacement wins and opens")
        park.release()
        let loser = try await slower.value
        assert(loser == nil, "the superseded replacement opens nothing")
        assert(transport.opens == [first, live], "exactly one open per winning replacement")
        assert(transport.cancels == [first, superseded], "the winner cancels the ID the superseded call had already minted")
        assert(carrier.admit(delta(live)) != nil, "the winner is admitted")
        assert(carrier.admit(delta(superseded)) == nil, "the superseded ID never streams")
        print("PASS overlapping replacements: the newest subscription is the only one opened")
    }

    /// A to B to nil: every step retires the previous conversation stream before
    /// its cancel is on the wire, so no frame of a session the user left can
    /// land, and a deselect opens nothing.
    @MainActor
    static func deselectIdentity() async throws {
        let transport = FakeRemoteTransport()
        let carrier = RemoteStreamConnection()
        assert(carrier.beginAttempt(index: 1) != nil)
        let a = try unwrapped(try await carrier.subscribe(.conversation, endpoint: "session/follow",
                                                             args: conversationArgs("session-a"), on: transport), "A opens")
        let b = try unwrapped(try await carrier.subscribe(.conversation, endpoint: "session/follow",
                                                             args: conversationArgs("session-b"), on: transport), "B opens")
        assert(transport.cancels == [a], "A is cancelled before B opens")
        assert(transport.frames.last?["payload"]["args"]["request"]["address"]["sessionId"].string == "session-b",
               "the open addresses the newly selected session")
        try await carrier.cancel(.conversation, on: transport)
        assert(transport.cancels == [a, b], "the deselect cancels the live conversation stream")
        assert(carrier.admit(snapshot(a)) == nil && carrier.admit(delta(a)) == nil, "no frame of the left session lands")
        assert(carrier.admit(snapshot(b)) == nil, "the deselected session stops streaming too")
        assert(carrier.streams[.conversation].isEmpty)
        let sent = transport.frames.count
        try await carrier.cancel(.conversation, on: transport)
        assert(transport.frames.count == sent, "a deselect with nothing live sends nothing")
        // The baseline defect in one line: while the cancel of the replaced
        // stream is still on the wire, that stream is already stale. The old
        // implementation reassigned its follow ID only after the await, so a
        // frame arriving in that window still landed on the UI.
        let park = Park()
        let c = try unwrapped(try await carrier.subscribe(.conversation, endpoint: "session/follow",
                                                             args: conversationArgs("session-c"), on: transport), "C opens")
        transport.gate = { frame in if frame["type"].string == "cancel" { await park.wait() } }
        let switching = Task { try await carrier.subscribe(.conversation, endpoint: "session/follow",
                                                           args: conversationArgs("session-d"), on: transport) }
        await spin { park.isParked }
        assert(carrier.admit(snapshot(c)) == nil, "a frame of the stream being replaced is stale while its cancel is on the wire")
        park.release()
        let d = try unwrapped(try await switching.value, "the new selection opens after the cancel")
        assert(carrier.admit(snapshot(d)) != nil && carrier.admit(snapshot(c)) == nil)
        print("PASS A to B to nil: retire-before-await, one open per selection and no stream for a deselect")
    }

    /// A teardown while a replacement's cancel is on the wire: the open must
    /// never be sent, and the dead socket's stream must never be admitted.
    @MainActor
    static func teardownDuringCancel() async throws {
        let transport = FakeRemoteTransport()
        let carrier = RemoteStreamConnection()
        carrier.beginAttempt(index: 1)
        let live = try unwrapped(try await carrier.subscribe(.control, endpoint: "session/control", on: transport), "control opens")
        let park = Park()
        transport.gate = { frame in if frame["type"].string == "cancel" { await park.wait() } }
        let replacement = Task { try await carrier.subscribe(.control, endpoint: "session/control", on: transport) }
        await spin { park.isParked }
        carrier.stop()
        park.release()
        let opened = try await replacement.value
        assert(opened == nil, "a teardown during the cancel opens nothing")
        assert(transport.opens == [live], "no second open reached the dead socket")
        assert(carrier.admit(delta(live)) == nil, "the dead socket's stream is not admitted")
        assert(!carrier.hasOwnedWork, "a torn-down carrier owns no ping or refresh work")
        print("PASS disconnect during cancel: nothing is opened and nothing is admitted")
    }

    /// A refresh's result - success or failure - applies only while the attempt
    /// that scheduled it is still the live one; a reconnect cancels its work.
    @MainActor
    static func staleRefreshAfterReconnect() async throws {
        let carrier = RemoteStreamConnection()
        carrier.beginAttempt(index: 1)
        let park = Park()
        var applied: [String] = []
        let success = try unwrapped(carrier.scheduleRefresh { token in
            await park.wait()
            if carrier.isCurrent(token) { applied.append("success") }
        }, "a refresh on a live attempt is scheduled")
        assert(carrier.hasOwnedWork, "the scheduled refresh belongs to the attempt")
        assert(carrier.isCurrent(success))
        carrier.beginAttempt(index: 2)
        assert(!carrier.isCurrent(success), "the previous attempt's refresh token is refused")
        assert(!carrier.hasOwnedWork, "the reconnect cancelled the previous attempt's refresh work")
        park.release()
        await spin { !carrier.hasOwnedWork }
        assert(applied.isEmpty, "the dead attempt's refresh never applied")
        let failureToken = try unwrapped(carrier.scheduleRefresh { token in
            if carrier.isCurrent(token) { applied.append("error") }
        }, "a refresh on the new attempt is scheduled")
        assert(carrier.isCurrent(failureToken))
        carrier.stop()
        assert(!carrier.isCurrent(failureToken))
        await spin { !carrier.hasOwnedWork }
        assert(applied.isEmpty, "a refresh suspended by a disconnect applies nothing")
        print("PASS stale refresh: a reconnect refuses the old result and cancels its work")
    }

    /// The HTTP refresh runs off the receive path: frames keep arriving while
    /// the list request is still in flight.
    @MainActor
    static func delayedRefreshKeepsReceiving() async throws {
        let transport = FakeRemoteTransport()
        let carrier = RemoteStreamConnection()
        carrier.beginAttempt(index: 1)
        let events = try unwrapped(try await carrier.subscribe(.events, endpoint: "$events", on: transport), "events opens")
        let park = Park()
        let token = carrier.scheduleRefresh { _ in await park.wait() }
        assert(token != nil, "the ready handler can schedule its refresh")
        await spin { park.isParked }
        assert(carrier.admit(baseline(events)) != nil, "the ready baseline is admitted while the HTTP refresh is in flight")
        assert(carrier.admit(delta(events)) != nil, "live frames keep arriving while the HTTP refresh is in flight")
        park.release()
        await spin { !carrier.hasOwnedWork }
        assert(carrier.admit(delta(events)) != nil, "the socket stays live after the refresh returns")
        print("PASS delayed HTTP refresh: the receive path is never blocked by the list request")
    }

    /// The ping belongs to one attempt: a failure only reports and never
    /// reconnects, and an old attempt's ping cannot touch the new socket.
    @MainActor
    static func pingOwnership() async throws {
        let transport = FakeRemoteTransport()
        let carrier = RemoteStreamConnection()
        let clock = ManualClock()
        carrier.beginAttempt(index: 1)
        var failures: [String] = []
        carrier.startPing(interval: .seconds(15), sleep: { try await clock.sleep($0) }, ping: { try await transport.ping() },
                          onFailure: { attempt, error in failures.append("\(attempt.index):\(error.localizedDescription)") })
        await spin { clock.sleeps == 1 }
        clock.tick()
        await spin { transport.pings == 1 }
        transport.failPings(with: HarnessError(message: "ping failed"))
        await spin { clock.sleeps == 2 }
        clock.tick()
        await spin { !failures.isEmpty }
        assert(failures == ["1:ping failed"], "a failed ping reports once")
        assert(carrier.attempt?.index == 1, "a failed ping never rotates the attempt: the reader owns reconnecting")
        assert(!carrier.hasOwnedWork, "the failed ping task ends; nothing retries it")
        let live = try unwrapped(try await carrier.subscribe(.events, endpoint: "$events", on: transport), "the stream survives a ping failure")
        assert(carrier.admit(baseline(live)) != nil)
        // A late ping of a replaced attempt must not reach the new socket.
        let second = FakeRemoteTransport()
        let secondClock = ManualClock()
        let reconnected = RemoteStreamConnection()
        reconnected.beginAttempt(index: 1)
        var stale: [String] = []
        reconnected.startPing(interval: .seconds(15), sleep: { try await secondClock.sleep($0) }, ping: { try await second.ping() },
                              onFailure: { _, error in stale.append(error.localizedDescription) })
        await spin { secondClock.sleeps == 1 }
        reconnected.beginAttempt(index: 2)
        secondClock.tick()
        await Task.yield(); await Task.yield()
        assert(second.pings == 0 && stale.isEmpty, "an old attempt's ping cannot ping the new socket or report to the UI")
        print("PASS ping ownership: one ping per attempt, failure reports only, late ping is inert")
    }

    /// The carrier loop is the only retry owner and the only reporter of the
    /// final state: a superseded or stopped carrier retries nothing.
    @MainActor
    static func carrierLoopOwnsRetry() async throws {
        let transport = FakeRemoteTransport()
        let carrier = RemoteStreamConnection()
        var starts: [Int] = [], failures: [Int] = [], finishes = 0, backoffs: [Duration] = []
        await carrier.run(attempts: 3, backoff: { .seconds(min(8, 1 << $0)) }, sleep: { backoffs.append($0) }, body: { attempt in
            starts.append(attempt.index)
            if attempt.index < 3 { throw HarnessError(message: "socket \(attempt.index) died") }
            let opened = try await carrier.subscribe(.events, endpoint: "$events", on: transport)
            assert(opened != nil)
        }, onAttempt: { _ in }, onFailure: { attempt, _ in failures.append(attempt.index) }, onFinish: { finishes += 1 })
        assert(starts == [1, 2, 3] && failures == [1, 2], "each failed attempt is reported once, the third succeeds")
        assert(backoffs == [.seconds(1), .seconds(2)], "the documented limited retry policy is preserved")
        assert(finishes == 0, "a carrier that connected does not report its end")
        assert(transport.opens.count == 1, "only the winning attempt opened a stream")
        // Every attempt fails: the loop reports its end exactly once.
        let exhausted = RemoteStreamConnection()
        var exhaustedFailures = 0, exhaustedFinishes = 0, exhaustedAttempts = 0
        await exhausted.run(attempts: 3, sleep: { _ in }, body: { _ in throw HarnessError(message: "dead") },
                            onAttempt: { _ in exhaustedAttempts += 1 }, onFailure: { _, _ in exhaustedFailures += 1 },
                            onFinish: { exhaustedFinishes += 1 })
        assert(exhaustedAttempts == 3 && exhaustedFailures == 3 && exhaustedFinishes == 1,
               "an exhausted carrier reports connecting=false exactly once")
        // A disconnect during the backoff ends the loop: no further attempt, no
        // report for the connection that replaced it.
        let parked = Park()
        let stopped = RemoteStreamConnection()
        var stoppedAttempts = 0, stoppedFinishes = 0
        let task = Task {
            await stopped.run(attempts: 4, sleep: { _ in await parked.wait() }, body: { _ in throw HarnessError(message: "dead") },
                              onAttempt: { _ in stoppedAttempts += 1 }, onFailure: { _, _ in }, onFinish: { stoppedFinishes += 1 })
        }
        await spin { parked.isParked }
        stopped.stop()
        parked.release()
        await task.value
        assert(stoppedAttempts == 1 && stoppedFinishes == 0, "a stopped carrier retries nothing and reports nothing")
        print("PASS carrier loop: single retry owner, limited backoff, one final state report")
    }

    /// A reconnect is a clean slate: no stream ID, no owned work and no frame
    /// of the previous socket survives it, so the store's per-attempt reset of
    /// queues, jobs and projections starts from an empty table.
    @MainActor
    static func perAttemptCleanSlate() async throws {
        let transport = FakeRemoteTransport()
        let carrier = RemoteStreamConnection()
        carrier.beginAttempt(index: 1)
        var ids: [String] = []
        for (kind, endpoint) in [(HarnessStreamSet.Kind.events, "$events"), (.workspaces, "workspace/follow"),
                                 (.control, "session/control"), (.conversation, "session/follow")] {
            let id = try unwrapped(try await carrier.subscribe(kind, endpoint: endpoint, args: conversationArgs("s1"), on: transport), "\(kind) opens")
            ids.append(id)
        }
        assert(ids.allSatisfy { carrier.admit(baseline($0)) != nil })
        carrier.beginAttempt(index: 2)
        assert(ids.allSatisfy { carrier.admit(baseline($0)) == nil },
               "a control/jobs baseline of the dead socket cannot land on the new attempt")
        assert(HarnessStreamSet.Kind.allCases.allSatisfy { carrier.streams[$0].isEmpty })
        assert(!carrier.hasOwnedWork)
        // The fresh attempt mints new IDs for every stream, and the old ones
        // stay refused: a late frame can never be mistaken for the new state.
        var fresh: [String] = []
        for (kind, endpoint) in [(HarnessStreamSet.Kind.events, "$events"), (.workspaces, "workspace/follow"),
                                 (.control, "session/control"), (.conversation, "session/follow")] {
            let id = try unwrapped(try await carrier.subscribe(kind, endpoint: endpoint, args: conversationArgs("s1"), on: transport), "\(kind) reopens")
            fresh.append(id)
        }
        assert(Set(fresh).isDisjoint(with: Set(ids)), "a new attempt never reuses an old stream ID")
        assert(fresh.allSatisfy { carrier.admit(baseline($0)) != nil })
        print("PASS per-attempt clean slate: streams, queues/jobs baselines and catalog identity start empty")
    }

    /// Diagnostics stay bounded and credential-free.
    @MainActor
    static func diagnosticsAreSanitizedAndBounded() async throws {
        let leak = HarnessError(message: "GET https://dsh.example/?token=SECRET123 failed; Cookie: dsh=ABCDEF; Basic //user:pw@host")
        let record = RemoteStreamDiagnostic(stage: "websocket-failed", connected: false,
                                            details: ["closeCode": 1008, "attempt": 3, "stream": "workspaces",
                                                      "cookie": "dsh=ABCDEF", "prompt": "private text"],
                                            error: leak).record
        let text = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        assert(!text.contains("SECRET123") && !text.contains("ABCDEF") && !text.contains("user:pw"), "no credential survives a record")
        assert(record["closeCode"] as? Int == 1008 && record["attempt"] as? Int == 3 && record["stream"] as? String == "workspaces",
               "the actual close code, the attempt and the stream kind are kept")
        assert(record["cookie"] == nil && record["prompt"] == nil, "only app-produced detail keys are kept")
        assert((record["stage"] as? String) == "websocket-failed" && record["connected"] as? Bool == false)
        var history: [[String: Any]] = []
        for index in 0..<120 { history = RemoteStreamDiagnostic.appending(["n": index], to: history) }
        assert(history.count == RemoteStreamDiagnostic.historyLimit, "the diagnostic history is bounded")
        assert(history.first?["n"] as? Int == 40 && history.last?["n"] as? Int == 119, "the newest records are kept, the oldest drop")
        print("PASS diagnostics: bounded history, app-produced fields only, credentials redacted")
    }

    /// Opt-in live probe against a real DSH. It uses the production coordinator
    /// and a read-only session: 25 cancel/reopen on one socket, an idle
    /// ping/pong window, and a deliberate reconnect whose baseline restores a
    /// transcript. Without `DSH_STREAM_CHECK_COOKIE` or `DSH_LIVE_LOG` it does
    /// nothing at all.
    @MainActor
    static func liveProbe() async throws {
        guard let credentials = try await liveCredentials() else { return }
        var parts = URLComponents(url: credentials.base.appendingPathComponent("api/remote.mux"), resolvingAgainstBaseURL: false)!
        parts.scheme = credentials.base.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: parts.url!)
        request.setValue(credentials.cookie, forHTTPHeaderField: "Cookie")
        request.setValue(credentials.base.absoluteString, forHTTPHeaderField: "Origin")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let carrier = RemoteStreamConnection()
        func connect() -> URLSessionWebSocketTask {
            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 32 * 1024 * 1024
            socket.resume()
            return socket
        }
        /// Read frames until one is admitted for `kind` and satisfies `done`.
        /// Stale frames - the whole point of the coordinator - are ignored.
        func read(_ socket: URLSessionWebSocketTask, until done: (RemoteStreamConnection.Delivery) -> Bool) async throws -> RemoteStreamConnection.Delivery {
            while true {
                let message = try await socket.receive()
                let data: Data
                switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: continue }
                let frame = try JSON.decodeWire(data)
                guard let delivery = carrier.admit(frame) else { continue }
                if delivery.frame["type"].string == "error" {
                    throw Failure(message: "the server refused the \(delivery.kind) stream: " + delivery.frame["error"]["message"].string)
                }
                if delivery.frame["type"].string == "end" {
                    throw Failure(message: "the server ended the \(delivery.kind) stream during the probe")
                }
                if done(delivery) { return delivery }
            }
        }
        // Phase 1: 25 cancel/reopen cycles on one socket, all through the
        // coordinator's replacement path.
        let first = connect()
        guard carrier.beginAttempt(index: 1) != nil else { throw Failure(message: "the probe carrier is stopped") }
        let events = try unwrapped(try await carrier.subscribe(.events, endpoint: "$events", on: first), "events opens")
        _ = try await read(first) { $0.kind == .events && $0.frame["value"]["type"].string == "ready" }
        var opened = Set<String>([events])
        for _ in 0..<25 {
            let next = try unwrapped(try await carrier.subscribe(.workspaces, endpoint: "workspace/follow", on: first), "workspace stream opens")
            _ = try await read(first) { $0.kind == .workspaces && $0.frame["value"]["type"].string == "baseline" }
            assert(opened.insert(next).inserted, "the live probe never reused a stream ID")
        }
        assert(first.closeCode.rawValue == 0 || first.closeCode.rawValue == 1000,
               "the socket survived 25 cancel/reopen cycles (close code \(first.closeCode.rawValue))")
        // Phase 2: an idle window with the carrier's own 15-second ping. A
        // terminate for missed heartbeats would have no 1008 close code, which
        // is exactly how it is told apart from a refused duplicate-ID request.
        var pingFailures: [String] = []
        carrier.startPing(ping: { try await first.ping() }, onFailure: { _, error in pingFailures.append(error.localizedDescription) })
        let drain = Task { while !Task.isCancelled { _ = try? await first.receive() } }
        try await Task.sleep(for: .seconds(36))
        drain.cancel()
        assert(pingFailures.isEmpty, "the carrier ping survived the idle window: \(pingFailures)")
        assert(first.closeCode.rawValue == 0 || first.closeCode.rawValue == 1000,
               "the gateway did not terminate the idle socket (close code \(first.closeCode.rawValue); 1008 would mean a duplicate ID, a missing close code a missed heartbeat)")
        print("PASS live DSH: 25 unique-ID cancel/reopen cycles and an idle ping window on one socket")
        // Phase 3: a deliberate reconnect, re-armed the way the store does it
        // (disconnect, then a fresh carrier run). The new socket must deliver
        // the event and control baselines and a fresh session snapshot.
        first.cancel(with: .goingAway, reason: nil)
        guard let sessionId = try await liveFirstSession(credentials) else {
            print("SKIP live DSH reconnect: the Host has no session to follow")
            return
        }
        print("live DSH: following the read-only session chosen for the reconnect phase")
        let second = connect()
        _ = try await rearm(carrier)
        _ = try await carrier.subscribe(.events, endpoint: "$events", on: second)
        _ = try await read(second) { $0.kind == .events && $0.frame["value"]["type"].string == "ready" }
        _ = try await carrier.subscribe(.control, endpoint: "session/control", on: second)
        _ = try await read(second) { $0.kind == .control && $0.frame["value"]["type"].string == "baseline" }
        _ = try await carrier.subscribe(.conversation, endpoint: "session/follow", args: conversationArgs(sessionId), on: second)
        let snapshot = try await read(second) { $0.kind == .conversation && $0.frame["value"]["type"].string == "snapshot" }
        assert(snapshot.frame["value"]["cursor"].int >= 0, "the reconnected session restores a snapshot")
        print("PASS live DSH: reconnect delivers the event and control baselines and restores session \(sessionId) (cursor \(snapshot.frame["value"]["cursor"].int))")
        second.cancel(with: .goingAway, reason: nil)
        carrier.stop()
    }

    struct LiveCredentials { let base: URL; let cookie: String }

    /// Re-arm a stopped carrier the way the store does after a reconnect: the
    /// next `run` mints the new attempt, and this one stays live for the
    /// subscriptions that follow.
    @MainActor
    static func rearm(_ carrier: RemoteStreamConnection) async throws -> RemoteStreamConnection.Attempt {
        carrier.stop()
        var attempt: RemoteStreamConnection.Attempt?
        await carrier.run(attempts: 1, sleep: { _ in }, body: { attempt = $0 },
                          onAttempt: { _ in }, onFailure: { _, _ in }, onFinish: {})
        return try unwrapped(attempt, "the reconnected carrier mints an attempt")
    }

    /// The probe's read-only credentials: either the explicit cookie file the
    /// earlier probe used, or the launch URL in the running `dsh web` log. The
    /// token is exchanged for a session cookie over HTTP and never printed.
    @MainActor
    static func liveCredentials() async throws -> LiveCredentials? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["DSH_STREAM_CHECK_COOKIE"] {
            let auth = try JSON.decodeWire(Data(contentsOf: URL(fileURLWithPath: path)))
            guard let base = URL(string: auth["origin"].string), !auth["cookie"].string.isEmpty else {
                throw Failure(message: "the cookie file needs an origin and a cookie")
            }
            return LiveCredentials(base: base, cookie: auth["cookie"].string)
        }
        guard let path = environment["DSH_LIVE_LOG"] else { return nil }
        let log = try String(contentsOfFile: path, encoding: .utf8)
        guard let line = log.components(separatedBy: .newlines).last(where: { $0.hasPrefix("dsh web: ") }) else {
            throw Failure(message: "the log has no dsh web launch line")
        }
        let (base, token) = try HarnessAPI.parse(String(line.dropFirst("dsh web: ".count)))
        guard let token else { throw Failure(message: "the launch URL has no token") }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "token", value: token)]
        var request = URLRequest(url: components.url!)
        request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        // The session cookie arrives on the launch redirect itself, so the
        // redirect is not followed (the app's own NoRedirect delegate).
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure(message: "the launch URL did not answer") }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
        let cookie = HTTPCookie.requestHeaderFields(with: HTTPCookie.cookies(withResponseHeaderFields: headers, for: base))["Cookie"] ?? ""
        guard !cookie.isEmpty else { throw Failure(message: "the launch URL did not yield a session cookie") }
        return LiveCredentials(base: base, cookie: cookie)
    }

    /// The first id in `session/list` - a read-only lookup for the reconnect
    /// phase, so the probe never creates or mutates a session.
    @MainActor
    static func liveFirstSession(_ credentials: LiveCredentials) async throws -> String? {
        var request = URLRequest(url: credentials.base.appendingPathComponent("api/session/list"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.base.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(credentials.cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONEncoder().encode(JSON.object([
            "type": .string("client-request"), "rpcId": .string(UUID().uuidString), "method": .string("session/list"),
            "payload": .object(["args": .object(["_request": .object([:])])])
        ]))
        let (data, _) = try await URLSession.shared.data(for: request)
        let value = try JSON.decodeWire(data)["result"]["value"]
        let followable = value["items"].array.first { $0["origin"].string != "subagent" && !$0["sessionId"].string.isEmpty }
        return followable?["sessionId"].string
    }

    /// `assert` on an optional with a message that survives in the log.
    static func unwrapped<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message: message) }
        return value
    }
}
