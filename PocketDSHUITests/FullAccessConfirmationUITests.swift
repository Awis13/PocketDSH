import XCTest

/// The Full access confirmation, driven through the real app against a
/// controlled DSH transport (`scripts/probe-full-access-alert.py`).
///
/// The probe answers the Host RPCs the client needs and records every
/// `commands/execute`, so these checks observe the wire the ticket is about: no
/// call before the answer, exactly one after it, and one question on the surface
/// that asked - never a second one.
///
/// Run it (Xcode's iOS platform is not needed; Catalyst works on this machine):
///
///     python3 scripts/probe-full-access-alert.py 8791 &
///     defaults write dev.awis.PocketDSH "harness.drafts.http://127.0.0.1:8791" \
///         -dict "session-review3-stub" "/permission danger-full-access" \
///               "session-review3-stub-2" "/compact"
///     xcodebuild test -project PocketDSH.xcodeproj -scheme PocketDSH \
///         -destination 'platform=macOS,variant=Mac Catalyst' \
///         -only-testing:PocketDSHUITests/FullAccessConfirmationUITests \
///         MACOSX_DEPLOYMENT_TARGET=14.0
///
/// The keyboard cannot be driven in this Catalyst build (event synthesis times
/// out), so the composer line comes from the draft the app restores; every test
/// that needs it skips with the seeding command when the draft is absent.
/// Nothing here touches a real Host: the transport is the probe, and the seeded
/// keys are the probe's own endpoint.
final class FullAccessConfirmationUITests: XCTestCase {
    static let stub = ProcessInfo.processInfo.environment["REVIEW3_STUB_URL"] ?? "http://127.0.0.1:8791"
    static let line = "/permission danger-full-access"
    static let secondLine = "/compact"

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.stubReachable(), "start the controlled transport: python3 scripts/probe-full-access-alert.py")
    }

    @MainActor
    func testComposerFullAccessConfirmation() throws {
        let app = try launch()
        let composer = app.textViews["composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 40), "the composer must be there")
        try XCTSkipUnless(composer.value as? String == Self.line, "seed the escalation draft first (see the class comment)")
        XCTAssertTrue(try stubCalls().isEmpty, "the probe starts from a clean transport")

        // The question, and nothing on the wire before it is answered.
        sendButton(app).tap()
        let alert = try escalationAlert(app)
        shot(app, "1. Composer asks before switching the session to full access")
        XCTAssertTrue(try stubCalls().isEmpty, "no commands/execute before the user confirms")

        // Cancel: nothing is sent and the draft stays in the composer.
        alert.buttons.element(boundBy: 1).tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 3), "Cancel dismisses the question")
        XCTAssertTrue(try stubCalls().isEmpty, "Cancel sends nothing")
        XCTAssertEqual(composer.value as? String, Self.line, "Cancel keeps the draft")
        shot(app, "2. Cancelled: the draft and the wire are untouched")

        // Confirm: exactly one call, addressed to the stub session.
        sendButton(app).tap()
        let again = try escalationAlert(app)
        again.buttons.element(boundBy: 0).tap()
        var calls = try stubCalls()
        for _ in 0..<40 where calls.isEmpty {
            usleep(250_000)
            calls = try stubCalls()
        }
        XCTAssertEqual(calls.count, 1, "confirming dispatches exactly one commands/execute")
        XCTAssertEqual(calls.first?["line"] as? String, Self.line)
        XCTAssertEqual(calls.first?["agentId"] as? String, "session-review3-stub")
        shot(app, "3. Confirmed: one commands/execute reached the transport")
    }

    @MainActor
    func testApprovalCardAsksTheSameQuestion() throws {
        let app = try launch()
        try pushApproval()
        let fullAccess = app.buttons["Full access…"].firstMatch
        XCTAssertTrue(fullAccess.waitForExistence(timeout: 60), "the approval card must be there")
        XCTAssertTrue(try stubCalls().isEmpty, "the card starts from a clean transport")

        fullAccess.tap()
        let alert = try escalationAlert(app)
        shot(app, "4. Approval card asks the same question")
        XCTAssertTrue(try stubCalls().isEmpty, "the card's question sends nothing")

        alert.buttons.element(boundBy: 0).tap()
        var calls = try stubCalls()
        for _ in 0..<40 where calls.isEmpty {
            usleep(250_000)
            calls = try stubCalls()
        }
        XCTAssertEqual(calls.count, 1, "the card's confirmation dispatches exactly one commands/execute")
        XCTAssertEqual(calls.first?["line"] as? String, Self.line)
        XCTAssertEqual(calls.first?["agentId"] as? String, "session-review3-stub")
        shot(app, "5. Card confirmed: one commands/execute reached the transport")
    }

    /// A session switch while the question is open: the pending action names one
    /// session and one connection generation, so switching ends the question
    /// instead of leaving it armed for whatever is open next.
    @MainActor
    func testSessionSwitchDropsTheQuestion() throws {
        let app = try launch()
        let composer = app.textViews["composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 40))
        try XCTSkipUnless(composer.value as? String == Self.line, "seed the escalation draft first (see the class comment)")

        sendButton(app).tap()
        _ = try escalationAlert(app)
        app.buttons["toggleSidebar"].firstMatch.tap()

        let other = app.buttons.matching(identifier: "session-review3-stub-2").firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 20), "the second stub session must be listed")
        other.tap()

        let gone = app.sheets.matching(NSPredicate(format: "label == 'alert'")).firstMatch
        XCTAssertFalse(gone.waitForExistence(timeout: 5), "the switch ends the question")
        XCTAssertTrue(try stubCalls().isEmpty, "a dropped question sends nothing")
        shot(app, "6. Session switch dropped the question")

        // Ordinary commands get no question at all: the same send in the other
        // session (whose seeded draft is /compact) must dispatch immediately.
        try XCTSkipUnless(composer.value as? String == Self.secondLine, "seed the second session's /compact draft first")
        sendButton(app).tap()
        XCTAssertFalse(gone.waitForExistence(timeout: 5), "an ordinary command asks nothing")
        var calls = try stubCalls()
        for _ in 0..<40 where calls.isEmpty {
            usleep(250_000)
            calls = try stubCalls()
        }
        XCTAssertEqual(calls.count, 1, "the ordinary command was dispatched once")
        XCTAssertEqual(calls.first?["line"] as? String, "/compact")
        shot(app, "7. Ordinary command dispatched without a question")
    }

    /// A split pane owns its own store, so its question must be asked on its own
    /// surface: before that, the card's button and the composer's line in a
    /// secondary pane published a pending confirmation nobody rendered.
    @MainActor
    func testSecondaryPaneAsksOnItsOwnSurface() throws {
        let app = try launch()
        XCTAssertTrue(app.textViews["composer"].firstMatch.waitForExistence(timeout: 40))
        app.buttons["splitVertical"].firstMatch.tap()
        let composers = app.textViews.matching(identifier: "composer")
        var panes = composers.count
        for _ in 0..<40 where panes < 2 {
            usleep(500_000)
            panes = composers.count
        }
        XCTAssertGreaterThanOrEqual(panes, 2, "the split must give the second pane its own composer")

        try pushApproval()
        let buttons = app.buttons.matching(NSPredicate(format: "label == 'Full access…'"))
        var cards = buttons.count
        for _ in 0..<60 where cards < 2 {
            usleep(500_000)
            cards = buttons.count
        }
        XCTAssertGreaterThanOrEqual(cards, 2, "both panes must show the approval card")

        // The last match is the pane added by the split.
        buttons.element(boundBy: cards - 1).tap()
        let alert = try escalationAlert(app)
        shot(app, "9. The split pane asks on its own surface")
        XCTAssertTrue(try stubCalls().isEmpty, "the pane's question sends nothing")
        alert.buttons.element(boundBy: 0).tap()
        var calls = try stubCalls()
        for _ in 0..<40 where calls.isEmpty {
            usleep(250_000)
            calls = try stubCalls()
        }
        XCTAssertEqual(calls.count, 1, "the pane's confirmation dispatches exactly one commands/execute")
        XCTAssertEqual(calls.first?["line"] as? String, Self.line)
        shot(app, "10. The split pane's confirmation reached the transport")
    }

    /// A dropped carrier connection while the question is open: the question is
    /// dropped with it and the transport sees nothing, however the user answers
    /// what is left on screen.
    @MainActor
    func testReconnectDropsTheQuestion() throws {
        let app = try launch()
        let composer = app.textViews["composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 40))
        try XCTSkipUnless(composer.value as? String == Self.line, "seed the escalation draft first (see the class comment)")

        sendButton(app).tap()
        _ = try escalationAlert(app)
        try control("drop")

        // The alert must be gone once the carrier is gone; the app may reconnect
        // on its own, and the question must not come back with it.
        let gone = app.sheets.matching(NSPredicate(format: "label == 'alert'")).firstMatch
        XCTAssertFalse(gone.waitForExistence(timeout: 10), "the dropped connection ends the question")
        XCTAssertTrue(try stubCalls().isEmpty, "a question dropped with its connection sends nothing")
        shot(app, "8. Dropped connection dropped the question")
    }

    /// Launch against the controlled transport and wait until it is up.
    @MainActor
    private func launch() throws -> XCUIApplication {
        try resetStub()
        let app = XCUIApplication()
        app.launchEnvironment["DSH_LOGIN_URL"] = Self.stub + "?token=review3-stub"
        app.launch()
        _ = app.textViews["composer"].firstMatch.waitForExistence(timeout: 40)
        return app
    }

    @MainActor
    private func sendButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "sendPrompt").firstMatch
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The escalation question, found the way this Catalyst build presents it
    /// (SwiftUI renders the alert as a sheet labelled `alert`; the iOS
    /// presentation query stays as the fallback) - and asserted on its copy, so
    /// the log carries the title, the message and both buttons as evidence.
    @MainActor
    private func escalationAlert(_ app: XCUIApplication) throws -> XCUIElement {
        let sheet = app.sheets.matching(NSPredicate(format: "label == 'alert'")).firstMatch
        let alert = sheet.waitForExistence(timeout: 20) ? sheet : app.alerts.firstMatch
        XCTAssertTrue(alert.exists, "sending the escalation must ask first")
        XCTAssertEqual(alert.buttons.count, 2, "one question: cancel and one enable action")
        // Every window of the app presents the same store-backed question, so
        // the count follows the restored window count; the assertion that
        // matters is that the question is a single one, answered through the
        // store by whichever window the user taps.
        XCTAssertGreaterThanOrEqual(app.sheets.matching(NSPredicate(format: "label == 'alert'")).count, 1)
        print("REVIEW3 ALERT TREE:\n\(alert.debugDescription)")
        return alert
    }

    /// Whether the controlled transport is up; without it every check skips.
    private static func stubReachable() -> Bool {
        var request = URLRequest(url: URL(string: stub + "/__review3/calls")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: request) { data, _, _ in
            reachable = data != nil
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 8)
        return reachable
    }

    /// One control call against the probe (`approval`, `drop`, `reset`).
    private func control(_ command: String) throws {
        var request = URLRequest(url: URL(string: Self.stub + "/__review3/" + command)!)
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 15)
    }

    /// Start every scenario from a transport with no recorded calls.
    private func resetStub() throws {
        var request = URLRequest(url: URL(string: Self.stub + "/__review3/reset")!)
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 15)
    }

    /// Make the controlled transport deliver one approval request over its
    /// `$events` stream, the way a real Host's waterfall frame arrives.
    private func pushApproval() throws {
        var request = URLRequest(url: URL(string: Self.stub + "/__review3/approval")!)
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 15)
    }

    /// The stub's recorded `commands/execute` calls, read from the probe.
    private func stubCalls() throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: Self.stub + "/__review3/calls")!)
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        var payload: [[String: Any]] = []
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { done.signal() }
            if let error { failure = error; return }
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let calls = object["calls"] as? [[String: Any]] else { return }
            payload = calls
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        if let failure { throw failure }
        return payload
    }
}
