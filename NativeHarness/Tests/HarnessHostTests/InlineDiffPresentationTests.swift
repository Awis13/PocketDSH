import XCTest
import Foundation
import HarnessCore
@testable import harness

final class InlineDiffPresentationTests: XCTestCase {
    func testToolDiffsRoundTripLosslessly() throws {
        let event = NativeEvent(op: "toolResult", session: "s", id: "c1", text: "Updated a.txt", failed: false,
                                toolDiffs: [NativeInlineDiffHunk(path: "a.txt", oldText: nil, newText: "line")])
        let decoded = try JSONDecoder().decode(NativeEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded.toolDiffs, event.toolDiffs)
        XCTAssertTrue(decoded.extraFields.isEmpty, "A known field must not leak into unknown preservation")
    }

    func testInsertionAndReplacementBothRoundTrip() throws {
        let hunks = [NativeInlineDiffHunk(path: "a", oldText: nil, newText: "added"),
                     NativeInlineDiffHunk(path: "a", oldText: "old", newText: "new")]
        let decoded = try JSONDecoder().decode(NativeEvent.self, from: JSONEncoder().encode(NativeEvent(op: "toolResult", toolDiffs: hunks)))
        XCTAssertEqual(decoded.toolDiffs?.first?.oldText, nil)
        XCTAssertEqual(decoded.toolDiffs?.last?.oldText, "old")
        XCTAssertEqual(decoded.toolDiffs, hunks)
    }

    func testUnknownFieldsSurviveAlongsideToolDiffs() throws {
        let json = #"{"op":"toolResult","id":"c1","toolDiffs":[{"path":"a","oldText":null,"newText":"x"}],"futureToolDiffField":{"deep":[1,2,3]}}"#
        let event = try JSONDecoder().decode(NativeEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.toolDiffs?.first?.newText, "x")
        XCTAssertNotNil(event.extraFields["futureToolDiffField"])
        let round = try JSONDecoder().decode(NativeEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(round.extraFields["futureToolDiffField"], event.extraFields["futureToolDiffField"])
    }

    func testMalformedToolDiffsBecomeAnUnknownField() throws {
        let event = try JSONDecoder().decode(NativeEvent.self, from: Data(#"{"op":"toolResult","toolDiffs":"future-format"}"#.utf8))
        XCTAssertNil(event.toolDiffs)
        XCTAssertNotNil(event.extraFields["toolDiffs"], "An undecodable payload must not be dropped or disconnect the client")
    }

    func testSanitizedClampsOversizedHunksAndDropsEmptyPaths() {
        let huge = String(repeating: "x", count: 40_000)
        let bounded = NativeInlineDiffHunk.sanitized([
            NativeInlineDiffHunk(path: "big", oldText: nil, newText: huge),
            NativeInlineDiffHunk(path: "", oldText: "a", newText: "b")
        ])
        XCTAssertEqual(bounded.count, 1, "An empty path has no renderable identity and is dropped")
        XCTAssertLessThanOrEqual(bounded.first?.newText.utf8.count ?? 0, NativeDiffLimits.maximumFieldBytes)
    }

    func testSanitizedBoundsTotalBytes() {
        let chunk = String(repeating: "y", count: NativeDiffLimits.maximumFieldBytes)
        let hunks = (0..<40).map { NativeInlineDiffHunk(path: "f\($0)", oldText: nil, newText: chunk) }
        let bounded = NativeInlineDiffHunk.sanitized(hunks)
        let total = bounded.reduce(0) { $0 + ($1.oldText?.utf8.count ?? 0) + $1.newText.utf8.count }
        XCTAssertLessThanOrEqual(total, NativeDiffLimits.maximumTotalBytes)
        XCTAssertLessThan(bounded.count, hunks.count, "The total-bytes budget is enforced")
    }

    func testJournalReplayKeepsToolDiffs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try PresentationJournal(path: root.appendingPathComponent("ui.sqlite").path)
        let info = NativeSessionInfo(id: "s", title: "t", workspace: root.path, model: "m", running: false, updatedAt: 0)
        try journal.register(session: "s", metadata: JSONEncoder().encode(info))
        let hunk = NativeInlineDiffHunk(path: "a.txt", oldText: "old", newText: "new")
        let event = NativeEvent(op: "toolResult", session: "s", id: "c1", text: "Updated a.txt", failed: false, toolDiffs: [hunk])
        try journal.append(session: "s", sequence: 1, event: JSONEncoder().encode(event), metadata: JSONEncoder().encode(info))
        let replayed = try journal.load(session: "s").map { try JSONDecoder().decode(NativeEvent.self, from: $0) }
        XCTAssertEqual(replayed.last?.toolDiffs, [hunk])
    }

    func testInterruptedRecoveryHasNoInlineDiff() {
        let call = NativeEvent(op: "toolCall", session: "s", id: "c1", text: "edit_file")
        let repaired = NativeRecovery.events([call], session: "s", engineInterrupted: true, pendingCount: 0)
        let result = repaired.first { $0.op == "toolResult" }
        XCTAssertNotNil(result)
        XCTAssertNil(result?.toolDiffs, "A recovered tool result has no reliable diff")
    }
}
