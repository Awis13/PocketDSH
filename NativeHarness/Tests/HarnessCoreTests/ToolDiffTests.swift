import XCTest
@testable import HarnessCore

final class ToolDiffTests: XCTestCase {
    func testIdenticalTextProducesNoHunks() {
        XCTAssertTrue(ToolDiff.hunks(path: "a.txt", before: "alpha\nbeta\n", after: "alpha\nbeta\n").isEmpty)
        XCTAssertTrue(ToolDiff.hunks(path: "a.txt", before: "", after: "").isEmpty)
        // Same lines, trailing-newline-only difference: nothing renderable changed.
        XCTAssertTrue(ToolDiff.hunks(path: "a.txt", before: "alpha", after: "alpha\n").isEmpty)
    }

    func testPureInsertionDropsOldTextAndKeepsContext() {
        let hunks = ToolDiff.hunks(path: "note.txt", before: "one\ntwo\n", after: "one\ninserted\ntwo\n")
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.path, "note.txt")
        XCTAssertNil(hunks.first?.oldText, "A pure insertion has no old side")
        XCTAssertEqual(hunks.first?.newText, "one\ninserted\ntwo", "Context 3 surrounds the inserted line")
    }

    func testReplacementCarriesThreeLinesOfContext() {
        let before = "l1\nl2\nl3\nl4\nold\nl6\nl7\nl8\nl9\n"
        let after = "l1\nl2\nl3\nl4\nnew\nl6\nl7\nl8\nl9\n"
        let hunks = ToolDiff.hunks(path: "f", before: before, after: after)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldText, "l2\nl3\nl4\nold\nl6\nl7\nl8")
        XCTAssertEqual(hunks.first?.newText, "l2\nl3\nl4\nnew\nl6\nl7\nl8")
    }

    func testDeletionOnlyKeepsAnEmptyNewSide() {
        let hunks = ToolDiff.hunks(path: "f", before: "only\n", after: "")
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldText, "only")
        XCTAssertEqual(hunks.first?.newText, "")
    }

    func testScatteredChangesBecomeSeparateHunks() {
        let before = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let after = before
            .replacingOccurrences(of: "line 2", with: "LINE 2")
            .replacingOccurrences(of: "line 18", with: "LINE 18")
        let hunks = ToolDiff.hunks(path: "f", before: before, after: after)
        XCTAssertEqual(hunks.count, 2, "Changes farther apart than 2×context split into hunks")
        XCTAssertEqual(hunks.first?.newText.contains("LINE 2"), true)
        XCTAssertEqual(hunks.last?.newText.contains("LINE 18"), true)
        XCTAssertEqual(hunks.first?.newText.contains("LINE 18"), false, "A hunk carries only its own region")
    }

    func testNearbyChangesMergeIntoOneHunk() {
        let before = (1...6).map { "line \($0)" }.joined(separator: "\n")
        let after = before
            .replacingOccurrences(of: "line 2", with: "LINE 2")
            .replacingOccurrences(of: "line 5", with: "LINE 5")
        XCTAssertEqual(ToolDiff.hunks(path: "f", before: before, after: after).count, 1,
                       "Changes within 2×context share one hunk")
    }

    func testEmptyAndSingleLineBoundaries() {
        let added = ToolDiff.hunks(path: "f", before: "", after: "hello\n")
        XCTAssertEqual(added.count, 1)
        XCTAssertNil(added.first?.oldText)
        XCTAssertEqual(added.first?.newText, "hello")

        let replaced = ToolDiff.hunks(path: "f", before: "old", after: "new")
        XCTAssertEqual(replaced.count, 1)
        XCTAssertEqual(replaced.first?.oldText, "old")
        XCTAssertEqual(replaced.first?.newText, "new")

        let grew = ToolDiff.hunks(path: "f", before: "a", after: "a\nb")
        XCTAssertNil(grew.first?.oldText)
        XCTAssertEqual(grew.first?.newText, "a\nb")
    }

    func testFieldsAreBoundedByLinesAndBytes() throws {
        let before = "same\n"
        let after = "same\n" + (0..<500).map { "added \($0)" }.joined(separator: "\n") + "\n"
        let hunks = ToolDiff.hunks(path: "f", before: before, after: after)
        let hunk = try XCTUnwrap(hunks.first)
        let lineCount = hunk.newText.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertLessThanOrEqual(lineCount, ToolDiffLimits.maximumLines)
        XCTAssertLessThanOrEqual(hunk.newText.utf8.count, ToolDiffLimits.maximumFieldBytes)
    }

    func testByteClampAppliesToASingleHugeLine() throws {
        let before = "same\n"
        let huge = String(repeating: "x", count: 40_000)
        let hunks = ToolDiff.hunks(path: "f", before: before, after: "same\n" + huge + "\n")
        let hunk = try XCTUnwrap(hunks.first)
        XCTAssertLessThanOrEqual(hunk.newText.utf8.count, ToolDiffLimits.maximumFieldBytes)
    }

    func testHunkCountIsBounded() {
        var beforeLines: [String] = []
        for i in 0..<250 {
            beforeLines.append("target \(i)")
            for g in 0..<7 { beforeLines.append("filler \(i)-\(g)") }
        }
        let afterLines = beforeLines.map { $0.hasPrefix("target ") ? "TARGET " + $0.dropFirst("target ".count) : $0 }
        let hunks = ToolDiff.hunks(path: "f", before: beforeLines.joined(separator: "\n"), after: afterLines.joined(separator: "\n"))
        XCTAssertEqual(hunks.count, ToolDiffLimits.maximumHunks, "Hunk count is capped")
    }
}
