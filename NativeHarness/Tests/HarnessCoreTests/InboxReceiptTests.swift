import XCTest
import Foundation
import CSQLite
@testable import HarnessCore

@MainActor
final class InboxReceiptTests: XCTestCase {
    private var root: URL!
    private var store: EventStore!

    private func prepare() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory
        store = try EventStore(path: directory.appendingPathComponent("db").path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    /// Raw access to the live store file, so a test can corrupt a receipt or
    /// install a trigger the actor itself can never create.
    @discardableResult private func sql(_ sql: String, _ arguments: [String] = []) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("db").path, &db) == SQLITE_OK else { throw HarnessError.storage("fixture open") }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HarnessError.storage(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, text) in arguments.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(index + 1), text, -1, transient) == SQLITE_OK else {
                throw HarnessError.storage("fixture bind")
            }
        }
        var result: [[String]] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw HarnessError.storage(String(cString: sqlite3_errmsg(db))) }
            result.append((0..<sqlite3_column_count(stmt)).map { String(cString: sqlite3_column_text(stmt, $0)!) })
        }
    }

    private func expectConflict(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("A changed payload with the same request ID must be refused") }
        catch HarnessError.invalid { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testIdenticalRepeatedIDReturnsDuplicateTrueAndOnePendingRow() async throws {
        try prepare()
        let first = try await store.enqueue(session: "s1", id: "cmd-1", prompt: "p1", mode: .queue)
        let second = try await store.enqueue(session: "s1", id: "cmd-1", prompt: "p1", mode: .queue)

        let firstDuplicate = first.duplicate
        let secondDuplicate = second.duplicate
        let firstID = first.id
        let secondID = second.id
        let firstState = first.state
        let secondState = second.state

        let pending = try await store.pending(session: "s1")
        let pendingCount = pending.count
        let pendingIDs = pending.map(\.id)

        XCTAssertTrue(firstID == "cmd-1")
        XCTAssertTrue(secondID == "cmd-1")
        XCTAssertFalse(firstDuplicate)
        XCTAssertTrue(secondDuplicate)
        XCTAssertEqual(firstState, .pending)
        XCTAssertEqual(secondState, .pending)
        XCTAssertEqual(pendingCount, 1)
        XCTAssertEqual(pendingIDs, ["cmd-1"])
    }

    func testChangedPromptOrModeWithSameIDThrowsAndOriginalPendingUnchanged() async throws {
        try prepare()
        let original = try await store.enqueue(session: "s2", id: "cmd-2", prompt: "original", mode: .queue)
        let originalID = original.id
        let originalState = original.state

        do {
            _ = try await store.enqueue(session: "s2", id: "cmd-2", prompt: "changed", mode: .queue)
            XCTFail("Expected error for changed prompt")
        } catch {
            // Expected
        }

        do {
            _ = try await store.enqueue(session: "s2", id: "cmd-2", prompt: "original", mode: .steer)
            XCTFail("Expected error for changed mode")
        } catch { }
        let pendingAfterChange = try await store.pending(session: "s2")
        let pendingCountAfterChange = pendingAfterChange.count
        let pendingPromptAfterChange = pendingAfterChange.first?.prompt
        let pendingModeAfterChange = pendingAfterChange.first?.mode

        XCTAssertEqual(originalID, "cmd-2")
        XCTAssertEqual(originalState, .pending)
        XCTAssertEqual(pendingCountAfterChange, 1)
        XCTAssertEqual(pendingPromptAfterChange, "original")
        XCTAssertEqual(pendingModeAfterChange, .queue)
    }

    func testRemovedIDReturnsStateCancelledOnIdenticalRetryAndIsNotPending() async throws {
        try prepare()
        let initial = try await store.enqueue(session: "s3", id: "cmd-3", prompt: "p3", mode: .steer)
        let initialID = initial.id

        let removed = try await store.removePending(session: "s3", id: "cmd-3")
        let removedResult = removed

        let retry = try await store.enqueue(session: "s3", id: "cmd-3", prompt: "p3", mode: .steer)
        let retryState = retry.state
        let retryID = retry.id

        let pendingAfterRemove = try await store.pending(session: "s3")
        let pendingCountAfterRemove = pendingAfterRemove.count
        let pendingIDsAfterRemove = pendingAfterRemove.map(\.id)

        XCTAssertEqual(initialID, "cmd-3")
        XCTAssertTrue(removedResult)
        XCTAssertEqual(retryID, "cmd-3")
        XCTAssertEqual(retryState, .cancelled)
        XCTAssertEqual(pendingCountAfterRemove, 0)
        XCTAssertTrue(pendingIDsAfterRemove.isEmpty)
    }

    func testEditPendingReplacesPromptInPlaceKeepsIdentityAndMode() async throws {
        try prepare()
        _ = try await store.enqueue(session: "s4", id: "cmd-4", prompt: "original", mode: .steer)

        let edited = try await store.editPending(session: "s4", id: "cmd-4", prompt: "replacement")
        let pending = try await store.pending(session: "s4")

        XCTAssertTrue(edited)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, "cmd-4")
        XCTAssertEqual(pending.first?.prompt, "replacement")
        XCTAssertEqual(pending.first?.mode, .steer)

        // The ID now carries the replacement payload, so the original is a
        // different-payload rejection rather than a silent resurrection.
        do {
            _ = try await store.enqueue(session: "s4", id: "cmd-4", prompt: "original", mode: .steer)
            XCTFail("Expected different-payload rejection after edit")
        } catch { }
        let stillPending = try await store.pending(session: "s4")
        XCTAssertEqual(stillPending.map(\.prompt), ["replacement"])
    }

    func testEditPendingRejectsEmptyPromptAndReportsMissingItemsAsFalse() async throws {
        try prepare()
        _ = try await store.enqueue(session: "s5", id: "cmd-5", prompt: "keep", mode: .queue)
        do {
            _ = try await store.editPending(session: "s5", id: "cmd-5", prompt: "   ")
            XCTFail("Expected empty prompt rejection")
        } catch { }
        let removed = try await store.editPending(session: "s5", id: "missing", prompt: "text")
        let edited = try await store.editPending(session: "s5", id: "cmd-5", prompt: "keep")
        _ = try await store.removePending(session: "s5", id: "cmd-5")
        let afterRemove = try await store.editPending(session: "s5", id: "cmd-5", prompt: "text")
        let pending = try await store.pending(session: "s5")

        XCTAssertFalse(removed)
        XCTAssertTrue(edited)
        XCTAssertFalse(afterRemove)
        XCTAssertTrue(pending.isEmpty)
    }

    func testEditPendingReturnsFalseForConsumedCommand() async throws {
        try prepare()
        _ = try await store.enqueue(session: "s6", id: "cmd-6", prompt: "one", mode: .queue)
        try await store.acquireExecution(session: "s6", owner: "owner")
        _ = try await store.claim(session: "s6", owner: "owner", startsTurn: true, trace: DiagnosticTrace().identifiers())

        let edited = try await store.editPending(session: "s6", id: "cmd-6", prompt: "two")
        let pending = try await store.pending(session: "s6")

        XCTAssertFalse(edited)
        XCTAssertTrue(pending.isEmpty)
        await store.releaseExecution(session: "s6", owner: "owner")
    }

    func testSteerPendingConvertsQueuedPendingCommandsAndIsIdempotent() async throws {
        try prepare()
        _ = try await store.enqueue(session: "s7", id: "queued", prompt: "q", mode: .queue)
        _ = try await store.enqueue(session: "s7", id: "already", prompt: "a", mode: .steer)

        let converted = try await store.steerPending(session: "s7", id: "queued")
        // A retried steer of an already-steering item is an idempotent success so
        // it can survive a host restart without reporting not-found.
        let reconverted = try await store.steerPending(session: "s7", id: "queued")
        let alreadySteering = try await store.steerPending(session: "s7", id: "already")
        let missing = try await store.steerPending(session: "s7", id: "unknown")
        let pending = try await store.pending(session: "s7")

        let queuedMode = try await store.commandMode(session: "s7", id: "queued")
        let missingMode = try await store.commandMode(session: "s7", id: "unknown")

        XCTAssertTrue(converted)
        XCTAssertTrue(reconverted)
        XCTAssertTrue(alreadySteering)
        XCTAssertFalse(missing)
        XCTAssertNil(missingMode)
        XCTAssertEqual(queuedMode, .steer)
        XCTAssertEqual(pending.first { $0.id == "queued" }?.mode, .steer)
        XCTAssertEqual(pending.first { $0.id == "already" }?.mode, .steer)
    }

    func testRemoveAndSteerRetriesAreIdempotentAcrossRestart() async throws {
        try prepare()
        _ = try await store.enqueue(session: "s8", id: "rm", prompt: "p", mode: .queue)
        _ = try await store.enqueue(session: "s8", id: "st", prompt: "p", mode: .queue)
        _ = try await store.enqueue(session: "s8", id: "ran", prompt: "p", mode: .queue)

        let removedOnce = try await store.removePending(session: "s8", id: "rm")
        // These legacy bool mutators stay idempotent without a request receipt.
        let removedTwice = try await store.removePending(session: "s8", id: "rm")
        let steeredOnce = try await store.steerPending(session: "s8", id: "st")
        let steeredTwice = try await store.steerPending(session: "s8", id: "st")

        // Claim the steer plus the queued item, then retry controls on consumed rows.
        try await store.acquireExecution(session: "s8", owner: "owner")
        _ = try await store.claim(session: "s8", owner: "owner", startsTurn: true, trace: DiagnosticTrace().identifiers())
        let removeConsumed = try await store.removePending(session: "s8", id: "ran")
        let steerConsumed = try await store.steerPending(session: "s8", id: "ran")
        // An already-steered command that has since run stays an idempotent success.
        let steerConsumedSteer = try await store.steerPending(session: "s8", id: "st")
        await store.releaseExecution(session: "s8", owner: "owner")

        XCTAssertTrue(removedOnce)
        XCTAssertTrue(removedTwice)
        XCTAssertTrue(steeredOnce)
        XCTAssertTrue(steeredTwice)
        XCTAssertFalse(removeConsumed)
        XCTAssertFalse(steerConsumed)
        XCTAssertTrue(steerConsumedSteer)
    }

    func testFingerprintIsCanonicalAndExcludesPlaintext() {
        let canary = "PLAINTEXT_CANARY_12345"
        let digest = QueueControlFingerprint.digest(action: .edit, itemID: "item", text: canary)
        XCTAssertEqual(digest.count, 64)
        XCTAssertFalse(digest.contains(canary))
        // Length framing prevents a delimiter inside one value from colliding
        // with a field boundary in another.
        XCTAssertNotEqual(QueueControlFingerprint.digest(action: .edit, itemID: "a|b", text: "c"),
                          QueueControlFingerprint.digest(action: .edit, itemID: "a", text: "b|c"))
        XCTAssertNotEqual(QueueControlFingerprint.digest(action: .edit, itemID: "x", text: nil),
                          QueueControlFingerprint.digest(action: .edit, itemID: "x", text: ""))
        XCTAssertNotEqual(QueueControlFingerprint.digest(action: .remove, itemID: "x", text: nil),
                          QueueControlFingerprint.digest(action: .steer, itemID: "x", text: nil))
        // Text is bound only for edit; remove ignores any stray text.
        XCTAssertEqual(QueueControlFingerprint.digest(action: .remove, itemID: "x", text: "ignored"),
                       QueueControlFingerprint.digest(action: .remove, itemID: "x", text: nil))
    }

    func testPersistedReceiptStoresDigestAndOutcomeWithoutPlaintext() async throws {
        try prepare()
        let canary = "PLAINTEXT_CANARY_98765"
        _ = try await store.enqueue(session: "s", id: "item", prompt: "original", mode: .queue)
        _ = try await store.queueControl(session: "s", requestID: "r", action: .edit, itemID: "item", text: canary, steeringAvailable: false)
        let rows = try sql("SELECT fingerprint,receipt FROM queue_operations WHERE session='s' AND id='r'")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][1], "accepted")
        XCTAssertEqual(rows[0][0].count, 64)
        XCTAssertFalse(rows[0][0].contains(canary))
        // The command row still carries the edit; only the receipt is a digest.
        XCTAssertEqual(try sql("SELECT prompt FROM commands WHERE session='s' AND id='item'"), [[canary]])
    }

    func testExactRetryReplaysStoredOutcomeAfterReopenAndKeepsLaterEdit() async throws {
        try prepare()
        let path = root.appendingPathComponent("db").path
        // Release the fixture store so this test owns the file for its reopen.
        store = nil
        do {
            let store = try EventStore(path: path)
            _ = try await store.enqueue(session: "s", id: "item", prompt: "original", mode: .queue)
            let first = try await store.queueControl(session: "s", requestID: "r-a", action: .edit, itemID: "item", text: "A", steeringAvailable: false)
            XCTAssertEqual(first, .fresh(QueueControlReceipt(requestID: "r-a", outcome: .accepted)))
            _ = try await store.queueControl(session: "s", requestID: "r-b", action: .edit, itemID: "item", text: "B", steeringAvailable: false)
            // The lookup is durable even inside one process, not an in-memory cache.
            let inProcess = try await store.queueControl(session: "s", requestID: "r-a", action: .edit, itemID: "item", text: "A", steeringAvailable: false)
            XCTAssertTrue(inProcess.replayed)
            XCTAssertEqual(inProcess.receipt.outcome, .accepted)
            let afterLaterEdit = try await store.pending(session: "s")
            XCTAssertEqual(afterLaterEdit.first?.prompt, "B")
        }
        let reopened = try EventStore(path: path)
        let replay = try await reopened.queueControl(session: "s", requestID: "r-a", action: .edit, itemID: "item", text: "A", steeringAvailable: false)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.receipt, QueueControlReceipt(requestID: "r-a", outcome: .accepted))
        // Retry A must not roll the queue back to A.
        let afterReplay = try await reopened.pending(session: "s")
        XCTAssertEqual(afterReplay.first?.prompt, "B")
        let edits = try await reopened.load(session: "s").filter { $0.kind == "inbox.edited" }
        XCTAssertEqual(edits.count, 2, "A replayed receipt must not re-emit the audit event")
    }

    func testChangedActionItemOrEditTextConflictsWithZeroMutation() async throws {
        try prepare()
        _ = try await store.enqueue(session: "s", id: "item", prompt: "original", mode: .queue)
        _ = try await store.queueControl(session: "s", requestID: "r", action: .edit, itemID: "item", text: "A", steeringAvailable: false)
        await expectConflict { _ = try await self.store.queueControl(session: "s", requestID: "r", action: .edit, itemID: "item", text: "changed", steeringAvailable: false) }
        await expectConflict { _ = try await self.store.queueControl(session: "s", requestID: "r", action: .edit, itemID: "other", text: "A", steeringAvailable: false) }
        await expectConflict { _ = try await self.store.queueControl(session: "s", requestID: "r", action: .remove, itemID: "item", text: nil, steeringAvailable: false) }
        await expectConflict { _ = try await self.store.queueControl(session: "s", requestID: "r", action: .steer, itemID: "item", text: nil, steeringAvailable: false) }
        let pending = try await store.pending(session: "s")
        XCTAssertEqual(pending.map(\.prompt), ["A"])
        XCTAssertEqual(pending.map(\.mode), [.queue])
        let events = try await store.load(session: "s")
        XCTAssertEqual(events.filter { $0.kind == "inbox.edited" }.count, 1)
        XCTAssertFalse(events.contains { $0.kind == "inbox.cancelled" || $0.kind == "inbox.steered" })
    }

    func testRejectedSteerReceiptSurvivesAvailabilityChange() async throws {
        try prepare()
        // Missing while idle is a durable steer-unavailable.
        let idle = try await store.queueControl(session: "s", requestID: "r-idle", action: .steer, itemID: "missing", text: nil, steeringAvailable: false)
        XCTAssertEqual(idle.receipt.outcome, .rejected(.steerUnavailable))
        let retryRunning = try await store.queueControl(session: "s", requestID: "r-idle", action: .steer, itemID: "missing", text: nil, steeringAvailable: true)
        XCTAssertTrue(retryRunning.replayed)
        XCTAssertEqual(retryRunning.receipt.outcome, .rejected(.steerUnavailable))
        // Missing while running is a durable not-found.
        let running = try await store.queueControl(session: "s", requestID: "r-run", action: .steer, itemID: "missing", text: nil, steeringAvailable: true)
        XCTAssertEqual(running.receipt.outcome, .rejected(.itemNotFound))
        let retryIdle = try await store.queueControl(session: "s", requestID: "r-run", action: .steer, itemID: "missing", text: nil, steeringAvailable: false)
        XCTAssertTrue(retryIdle.replayed)
        XCTAssertEqual(retryIdle.receipt.outcome, .rejected(.itemNotFound))
        let remaining = try await store.pending(session: "s")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testQueueReceiptsAreSessionScoped() async throws {
        try prepare()
        _ = try await store.enqueue(session: "a", id: "item-a", prompt: "a", mode: .queue)
        _ = try await store.enqueue(session: "b", id: "item-b", prompt: "b", mode: .queue)
        let a = try await store.queueControl(session: "a", requestID: "shared", action: .edit, itemID: "item-a", text: "for-a", steeringAvailable: false)
        let b = try await store.queueControl(session: "b", requestID: "shared", action: .edit, itemID: "item-b", text: "for-b", steeringAvailable: false)
        XCTAssertFalse(a.replayed)
        XCTAssertFalse(b.replayed)
        let pendingA = try await store.pending(session: "a")
        let pendingB = try await store.pending(session: "b")
        XCTAssertEqual(pendingA.first?.prompt, "for-a")
        XCTAssertEqual(pendingB.first?.prompt, "for-b")
        await expectConflict { _ = try await self.store.queueControl(session: "a", requestID: "shared", action: .edit, itemID: "item-a", text: "for-b", steeringAvailable: false) }
        let afterConflict = try await store.pending(session: "a")
        XCTAssertEqual(afterConflict.first?.prompt, "for-a")
    }

    func testCorruptReceiptIsStorageErrorWithoutReexecution() async throws {
        try prepare()
        _ = try await store.enqueue(session: "s", id: "item", prompt: "original", mode: .queue)
        _ = try await store.queueControl(session: "s", requestID: "r", action: .edit, itemID: "item", text: "A", steeringAvailable: false)
        try sql("UPDATE queue_operations SET receipt='not-an-outcome' WHERE session='s' AND id='r'")
        do {
            _ = try await store.queueControl(session: "s", requestID: "r", action: .edit, itemID: "item", text: "A", steeringAvailable: false)
            XCTFail("A corrupt receipt must never re-execute the action")
        } catch HarnessError.storage { }
        let corruptPending = try await store.pending(session: "s")
        let corruptEdits = try await store.load(session: "s").filter { $0.kind == "inbox.edited" }
        XCTAssertEqual(corruptPending.first?.prompt, "A")
        XCTAssertEqual(corruptEdits.count, 1)
    }

    func testCorruptFingerprintIsStorageErrorWithoutReexecution() async throws {
        try prepare()
        _ = try await store.enqueue(session: "s", id: "item", prompt: "original", mode: .queue)
        _ = try await store.queueControl(session: "s", requestID: "r", action: .edit, itemID: "item", text: "A", steeringAvailable: false)
        let original = try sql("SELECT fingerprint FROM queue_operations WHERE session='s' AND id='r'").first?.first
        let canonical = try XCTUnwrap(original)
        XCTAssertTrue(QueueControlFingerprint.isCanonical(canonical))
        // Corrupt only the persisted fingerprint; the stored outcome still parses.
        try sql("UPDATE queue_operations SET fingerprint='not-a-sha256' WHERE session='s' AND id='r'")
        do {
            _ = try await store.queueControl(session: "s", requestID: "r", action: .edit, itemID: "item", text: "A", steeringAvailable: false)
            XCTFail("A corrupt fingerprint must be a storage error, not a client conflict")
        } catch HarnessError.storage {
        } catch HarnessError.invalid {
            XCTFail("A corrupt fingerprint must not surface as a request-ID conflict")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let pending = try await store.pending(session: "s")
        let edits = try await store.load(session: "s").filter { $0.kind == "inbox.edited" }
        XCTAssertEqual(pending.first?.prompt, "A", "A corrupt fingerprint must not re-execute the action")
        XCTAssertEqual(edits.count, 1, "A corrupt fingerprint must not add an audit event")
        // Restoring the canonical digest lets the legitimate exact retry replay.
        try sql("UPDATE queue_operations SET fingerprint=? WHERE session='s' AND id='r'", [canonical])
        let replay = try await store.queueControl(session: "s", requestID: "r", action: .edit, itemID: "item", text: "A", steeringAvailable: false)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.receipt.outcome, .accepted)
        let replayedPending = try await store.pending(session: "s")
        XCTAssertEqual(replayedPending.first?.prompt, "A")
    }

    func testReceiptInsertFailureRollsBackMutationAndAudit() async throws {
        try prepare()
        _ = try await store.enqueue(session: "s", id: "item", prompt: "original", mode: .queue)
        try sql("CREATE TRIGGER refuse_queue_receipt BEFORE INSERT ON queue_operations BEGIN SELECT RAISE(ABORT,'injected'); END")
        do {
            _ = try await store.queueControl(session: "s", requestID: "r", action: .edit, itemID: "item", text: "A", steeringAvailable: false)
            XCTFail("A failed receipt insert must roll the whole control back")
        } catch HarnessError.storage { }
        // Command mutation and audit event must both be gone with the receipt.
        let rolledBackPending = try await store.pending(session: "s")
        let rolledBackEdits = try await store.load(session: "s").filter { $0.kind == "inbox.edited" }
        let rolledBackReceipt = try await store.queueControlReceipt(session: "s", requestID: "r")
        XCTAssertEqual(rolledBackPending.first?.prompt, "original")
        XCTAssertTrue(rolledBackEdits.isEmpty)
        XCTAssertNil(rolledBackReceipt)
        try sql("DROP TRIGGER refuse_queue_receipt")
        let retry = try await store.queueControl(session: "s", requestID: "r", action: .edit, itemID: "item", text: "A", steeringAvailable: false)
        XCTAssertFalse(retry.replayed)
        XCTAssertEqual(retry.receipt.outcome, .accepted)
        let committedPending = try await store.pending(session: "s")
        XCTAssertEqual(committedPending.first?.prompt, "A")
    }
}