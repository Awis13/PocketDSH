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
}