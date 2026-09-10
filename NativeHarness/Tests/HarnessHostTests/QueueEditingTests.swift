import XCTest
import HarnessCore
@testable import harness

final class QueueEditingTests: XCTestCase {
    /// Editing must only re-emit a `user` row for a request that was actually
    /// shown to the user. Agent/`watch` items are enqueued straight into the
    /// inbox (`driver.submit`) and never emitted one, so editing them must not
    /// fabricate a phantom user message.
    func testEditOnlyReemitsAnAdmittedUserRow() {
        XCTAssertTrue(NativeQueueEditing.reemitsUser(admitted: ["q1"], itemID: "q1", edited: true, previousPrompt: "old", updatedPrompt: "new"))
        XCTAssertFalse(NativeQueueEditing.reemitsUser(admitted: ["q1"], itemID: "agent-task", edited: true, previousPrompt: "old", updatedPrompt: "new"),
                       "An item with no user row must not produce a phantom one")
        XCTAssertFalse(NativeQueueEditing.reemitsUser(admitted: ["q1"], itemID: "q1", edited: true, previousPrompt: "same", updatedPrompt: "same"),
                       "An unchanged prompt has nothing to reconcile")
        XCTAssertFalse(NativeQueueEditing.reemitsUser(admitted: ["q1"], itemID: "q1", edited: false, previousPrompt: nil, updatedPrompt: "new"),
                       "A failed edit (already consumed/cancelled) must not re-emit")
    }

    /// The full-text fetch and *both* rejection paths carry the queue item id,
    /// which is what the client keys its editor handler on. The previous
    /// request-id rejection left the editor spinning forever.
    func testTextFetchAndRejectionsCarryTheItemIdentity() {
        let found = NativeQueueEditing.textResult(session: "s", itemID: "item-1", prompt: "full text")
        XCTAssertEqual(found.op, "queueText")
        XCTAssertEqual(found.id, "item-1")
        XCTAssertEqual(found.text, "full text")

        let missing = NativeQueueEditing.textResult(session: "s", itemID: "item-1", prompt: nil)
        XCTAssertEqual(missing.op, "queueRejected")
        XCTAssertEqual(missing.id, "item-1")
        XCTAssertEqual(missing.text, "queue-item-not-found")

        let failure = NativeQueueEditing.textFailure(session: "s", itemID: "item-1")
        XCTAssertEqual(failure.op, "queueRejected")
        XCTAssertEqual(failure.id, "item-1")
        XCTAssertEqual(failure.text, "queue-unavailable")
    }
}
