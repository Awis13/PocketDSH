import XCTest
import Foundation
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
        // The receipt cache is in-memory only; a retry after restart must still succeed.
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
}