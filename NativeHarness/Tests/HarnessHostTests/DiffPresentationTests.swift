import XCTest
import HarnessCore
@testable import harness

final class DiffPresentationTests: XCTestCase {
    private func coreDiff() -> WorkspaceDiff {
        WorkspaceDiff(base: "HEAD", resolvedBase: "abc123",
                      files: [WorkspaceDiffFile(path: "a.txt", oldPath: nil, status: "modified", binary: false,
                                                additions: 1, deletions: 1, truncated: false,
                                                hunks: [WorkspaceDiffHunk(path: "a.txt", header: "@@ -1 +1 @@", oldText: "old", newText: "new")])],
                      truncated: false, error: nil)
    }

    func testPresentationMapsCoreDiffToWireEvent() throws {
        let event = NativeDiffPresentation.event(session: "s", requestID: "r", result: coreDiff())
        XCTAssertEqual(event.op, "diff")
        XCTAssertEqual(event.session, "s")
        XCTAssertEqual(event.id, "r")
        XCTAssertEqual(event.diff?.base, "HEAD")
        XCTAssertEqual(event.diff?.resolvedBase, "abc123")
        XCTAssertEqual(event.diff?.files.first?.status, "modified")
        XCTAssertEqual(event.diff?.files.first?.hunks.first?.newText, "new")

        let decoded = try JSONDecoder().decode(NativeEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded.diff, event.diff, "The additive diff payload must round-trip losslessly")
    }

    func testErrorEventCarriesABoundedMessage() {
        let event = NativeDiffPresentation.event(session: "s", requestID: nil, error: "not a git repository\nsecond line")
        XCTAssertEqual(event.op, "diff")
        XCTAssertNil(event.id)
        XCTAssertEqual(event.diff?.base, "HEAD")
        XCTAssertTrue(event.diff?.files.isEmpty == true)
        XCTAssertEqual(event.diff?.error?.contains("\n"), false, "Control characters are stripped from displayed errors")
        XCTAssertEqual(event.diff?.error, "not a git repositorysecond line")
    }

    func testCapabilityName() {
        XCTAssertEqual(NativeDiffInfo.capability, "workspace.diff.v1")
    }

    func testUnknownDiffFieldsSurviveDecodeAndEncode() throws {
        let json = #"{"op":"diff","session":"s","diff":{"base":"worktree","files":[]},"futureDiffField":{"deep":[1,2,3]}}"#
        let event = try JSONDecoder().decode(NativeEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.diff?.base, "worktree")
        XCTAssertNotNil(event.extraFields["futureDiffField"])
        let round = try JSONDecoder().decode(NativeEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(round.extraFields["futureDiffField"], event.extraFields["futureDiffField"])
    }

    func testSanitizeClampsOversizedHostPayload() {
        let longText = String(repeating: "x", count: 40_000)
        let info = NativeDiffInfo(base: "HEAD", files: [
            NativeDiffFile(path: "big.txt", oldPath: nil, status: "modified", binary: false, additions: 1, deletions: 0,
                           truncated: false, hunks: [NativeDiffHunk(path: "big.txt", header: "@@", oldText: "", newText: longText)])
        ], truncated: false, error: nil)
        let bounded = info.sanitized()
        XCTAssertTrue(bounded.truncated)
        XCTAssertLessThanOrEqual(bounded.files.first?.hunks.first?.newText.utf8.count ?? 0, NativeDiffLimits.maximumFieldBytes)
    }
}
