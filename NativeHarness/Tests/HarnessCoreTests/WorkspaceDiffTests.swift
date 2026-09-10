import XCTest
import Foundation
@testable import HarnessCore

final class WorkspaceDiffTests: XCTestCase, @unchecked Sendable {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await git(["init", "-q", "-b", "main"], at: dir)
        _ = try await git(["config", "user.email", "fixture@example.com"], at: dir)
        _ = try await git(["config", "user.name", "Fixture"], at: dir)
        return dir
    }

    private func git(_ arguments: [String], at directory: URL) async throws -> CommandBlock {
        try await ShellRunner.run(command: "git --no-pager -c core.quotePath=false " + arguments.joined(separator: " "),
                                  workspace: directory.path)
    }

    private func write(_ text: String, to directory: URL, _ name: String) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    func testModifiedFileProducesHunkAndCounts() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("one\ntwo\nthree\n", to: root, "a.txt")
        _ = try await git(["add", "a.txt"], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try write("one\nTWO\nthree\nfour\n", to: root, "a.txt")
        let diff = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: root.path)
        XCTAssertNil(diff.error)
        XCTAssertEqual(diff.files.map(\.path), ["a.txt"])
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.status, "modified")
        XCTAssertEqual(file.additions, 2)
        XCTAssertEqual(file.deletions, 1)
        XCTAssertFalse(file.binary)
        XCTAssertEqual(file.hunks.count, 2, "Zero-context hunks keep the added and changed lines separate")
        XCTAssertEqual(file.hunks.first?.oldText, "two")
        XCTAssertEqual(file.hunks.first?.newText, "TWO")
        XCTAssertEqual(file.hunks.last?.oldText, "")
        XCTAssertEqual(file.hunks.last?.newText, "four")
        XCTAssertFalse(diff.truncated)
    }

    func testAddedDeletedAndRenamedStatuses() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("keep\n", to: root, "keep.txt")
        try write("gone\n", to: root, "gone.txt")
        try write("old\n", to: root, "old.txt")
        _ = try await git(["add", "."], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try write("added\n", to: root, "added.txt")
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))
        _ = try await git(["add", "added.txt", "gone.txt"], at: root)
        _ = try await git(["mv", "old.txt", "renamed.txt"], at: root)
        let staged = try await WorkspaceDiffEngine.generate(base: .staged, workspace: root.path)
        let statuses = Dictionary(uniqueKeysWithValues: staged.files.map { ($0.path, $0.status) })
        XCTAssertEqual(statuses["added.txt"], "added")
        XCTAssertEqual(statuses["gone.txt"], "deleted")
        XCTAssertEqual(statuses["renamed.txt"], "renamed")
        XCTAssertEqual(staged.files.first(where: { $0.path == "renamed.txt" })?.oldPath, "old.txt")
        XCTAssertEqual(staged.files.first(where: { $0.path == "added.txt" })?.additions, 1)
        XCTAssertEqual(staged.files.first(where: { $0.path == "gone.txt" })?.deletions, 1)
    }

    func testUntrackedIncludedAsBoundedAddition() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", to: root, "base.txt")
        _ = try await git(["add", "base.txt"], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try write("fresh\nline\n", to: root, "new.txt")
        let worktree = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: root.path)
        let entry = try XCTUnwrap(worktree.files.first { $0.path == "new.txt" })
        XCTAssertEqual(entry.status, "untracked")
        XCTAssertEqual(entry.additions, 2)
        XCTAssertEqual(entry.hunks.first?.oldText, "")
        XCTAssertEqual(entry.hunks.first?.newText, "fresh\nline")
        let staged = try await WorkspaceDiffEngine.generate(base: .staged, workspace: root.path)
        XCTAssertFalse(staged.files.contains { $0.path == "new.txt" }, "Untracked files are not staged")
    }

    func testBinaryListedWithoutBody() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("bin.dat"))
        _ = try await git(["add", "bin.dat"], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try Data([0, 9, 9, 9]).write(to: root.appendingPathComponent("bin.dat"))
        let diff = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: root.path)
        let file = try XCTUnwrap(diff.files.first { $0.path == "bin.dat" })
        XCTAssertTrue(file.binary)
        XCTAssertTrue(file.hunks.isEmpty)
        XCTAssertEqual(file.additions, 0)
    }

    func testBinaryUntrackedListedWithoutBody() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("blob.bin"))
        let diff = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: root.path)
        let file = try XCTUnwrap(diff.files.first { $0.path == "blob.bin" })
        XCTAssertTrue(file.binary)
        XCTAssertTrue(file.hunks.isEmpty)
        XCTAssertEqual(file.status, "untracked")
    }

    func testEmptyDiffHasNoFilesOrError() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("stable\n", to: root, "a.txt")
        _ = try await git(["add", "a.txt"], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        let diff = try await WorkspaceDiffEngine.generate(base: .head, workspace: root.path)
        XCTAssertTrue(diff.files.isEmpty)
        XCTAssertNil(diff.error)
        XCTAssertFalse(diff.truncated)
        XCTAssertEqual(diff.base, "HEAD")
    }

    func testBranchBaseResolvesMergeBase() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("one\n", to: root, "a.txt")
        _ = try await git(["add", "a.txt"], at: root)
        _ = try await git(["commit", "-qm", "base"], at: root)
        _ = try await git(["checkout", "-qb", "feature"], at: root)
        try write("one\ntwo\n", to: root, "a.txt")
        _ = try await git(["commit", "-qam", "feature"], at: root)
        let diff = try await WorkspaceDiffEngine.generate(base: .ref("main"), workspace: root.path)
        let resolved = try XCTUnwrap(diff.resolvedBase)
        XCTAssertEqual(resolved.count, 40)
        XCTAssertTrue(resolved.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(diff.files.map(\.path), ["a.txt"])
        XCTAssertEqual(diff.files.first?.additions, 1)
    }

    func testNoCommonHistoryReportsError() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("one\n", to: root, "a.txt")
        _ = try await git(["add", "a.txt"], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        let diff = try await WorkspaceDiffEngine.generate(base: .ref("missing-branch"), workspace: root.path)
        XCTAssertNotNil(diff.error)
        XCTAssertTrue(diff.files.isEmpty)
    }

    func testNotARepositoryReportsError() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let diff = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: dir.path)
        XCTAssertNotNil(diff.error)
        XCTAssertTrue(diff.files.isEmpty)
    }

    func testBoundsTruncateLargeHunk() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write((0..<500).map(String.init).joined(separator: "\n") + "\n", to: root, "big.txt")
        _ = try await git(["add", "big.txt"], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try write((500..<1200).map(String.init).joined(separator: "\n") + "\n", to: root, "big.txt")
        let diff = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: root.path)
        XCTAssertTrue(diff.truncated)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertTrue(file.truncated)
        XCTAssertLessThanOrEqual(file.hunks.first?.newText.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0,
                                 WorkspaceDiffLimits.maximumLines)
    }

    func testClampKeepsUTF8Boundary() {
        let text = String(repeating: "😀", count: 100)
        let (clamped, trimmed) = WorkspaceDiffEngine.clamp(text, maxBytes: 16, maxLines: 300)
        XCTAssertTrue(trimmed)
        XCTAssertEqual(clamped, "😀😀😀😀")
        XCTAssertEqual(clamped.utf8.count, 16)
    }

    func testRefValidationRejectsEscapesAndOptions() {
        XCTAssertEqual(WorkspaceDiffBase("worktree"), .worktree)
        XCTAssertEqual(WorkspaceDiffBase("staged"), .staged)
        XCTAssertEqual(WorkspaceDiffBase("HEAD"), .head)
        XCTAssertEqual(WorkspaceDiffBase("main"), .ref("main"))
        XCTAssertEqual(WorkspaceDiffBase("origin/feature-1"), .ref("origin/feature-1"))
        XCTAssertNil(WorkspaceDiffBase(""))
        XCTAssertNil(WorkspaceDiffBase("-c"))
        XCTAssertNil(WorkspaceDiffBase("../../etc/passwd"))
        XCTAssertNil(WorkspaceDiffBase("main; rm -rf /"))
        XCTAssertNil(WorkspaceDiffBase("$(whoami)"))
        XCTAssertNil(WorkspaceDiffBase("a`b`"))
        XCTAssertNil(WorkspaceDiffBase("a b"))
        XCTAssertNil(WorkspaceDiffBase("foo\0bar"))
        XCTAssertNil(WorkspaceDiffBase(String(repeating: "a", count: WorkspaceDiffLimits.maximumRefBytes + 1)))
        XCTAssertNil(WorkspaceDiffBase("HEAD~1..HEAD"))
    }
}
