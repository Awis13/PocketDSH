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

    func testCountsMatchRenderedExcerptAfterClamp() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write((0..<500).map(String.init).joined(separator: "\n") + "\n", to: root, "big.txt")
        _ = try await git(["add", "big.txt"], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try write((0..<900).map(String.init).joined(separator: "\n") + "\n", to: root, "big.txt")
        let diff = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: root.path)
        let file = try XCTUnwrap(diff.files.first)
        func lines(_ text: String) -> Int {
            guard !text.isEmpty else { return 0 }
            return text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
        }
        XCTAssertTrue(file.truncated)
        XCTAssertEqual(file.additions, file.hunks.reduce(0) { $0 + lines($1.newText) },
                       "Header additions must describe the rendered excerpt, not the dropped lines")
        XCTAssertEqual(file.deletions, file.hunks.reduce(0) { $0 + lines($1.oldText) })
        XCTAssertLessThanOrEqual(file.additions, WorkspaceDiffLimits.maximumLines)
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

    // MARK: - Content lines that look like file headers (Critical)

    func testRemovedLineStartingWithDashesStaysContent() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("alpha\n-- old comment\nomega\n", to: root, "f.txt")
        _ = try await git(["add", "f.txt"], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try write("alpha\nomega\n", to: root, "f.txt")
        let diff = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: root.path)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.path, "f.txt", "`--- old comment` must not become the old-file header")
        XCTAssertEqual(file.status, "modified")
        XCTAssertEqual(file.additions, 0)
        XCTAssertEqual(file.deletions, 1, "The removed line must be counted, not eaten as a header")
        XCTAssertEqual(file.hunks.flatMap { $0.oldText.split(separator: "\n") }.map(String.init), ["-- old comment"])
    }

    func testAddedLineStartingWithPlusesStaysContent() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("alpha\n", to: root, "g.txt")
        _ = try await git(["add", "g.txt"], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try write("alpha\n++ plus comment\n", to: root, "g.txt")
        let diff = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: root.path)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.path, "g.txt", "`+++ plus comment` must not corrupt the new-file header")
        XCTAssertEqual(file.additions, 1, "The added line must be counted, not eaten as a header")
        XCTAssertEqual(file.deletions, 0)
        XCTAssertEqual(file.hunks.flatMap { $0.newText.split(separator: "\n") }.map(String.init), ["++ plus comment"])
    }

    func testDeletedFileContainingDashLineKeepsPath() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("-- old comment\ntail\n", to: root, "gone.txt")
        _ = try await git(["add", "gone.txt"], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))
        _ = try await git(["add", "-A"], at: root)
        let diff = try await WorkspaceDiffEngine.generate(base: .staged, workspace: root.path)
        let file = try XCTUnwrap(diff.files.first { $0.status == "deleted" })
        XCTAssertEqual(file.path, "gone.txt", "A deleted file must not be renamed to its own content")
        XCTAssertEqual(file.deletions, 2)
        XCTAssertEqual(file.hunks.first?.oldText, "-- old comment\ntail")
    }

    func testMultiFileHunksStayDelimitedWithHeaderLikeContent() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("keep\n-- old a\n", to: root, "a.txt")
        try write("keep\n-- old b\n", to: root, "b.txt")
        _ = try await git(["add", "."], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try write("keep\n", to: root, "a.txt")
        try write("keep\n", to: root, "b.txt")
        let diff = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: root.path)
        XCTAssertEqual(Set(diff.files.map(\.path)), ["a.txt", "b.txt"])
        for file in diff.files { XCTAssertEqual(file.deletions, 1) }
    }

    func testNoNewlineAtEndOfFileMarkerIsIgnored() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("one\n", to: root, "n.txt")
        _ = try await git(["add", "n.txt"], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try write("one", to: root, "n.txt")
        let diff = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: root.path)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.path, "n.txt")
        XCTAssertEqual(file.additions, 1)
        XCTAssertEqual(file.deletions, 1)
        XCTAssertEqual(file.hunks.first?.oldText, "one")
        XCTAssertEqual(file.hunks.first?.newText, "one")
    }

    // MARK: - Unborn HEAD

    func testUnbornHeadShowsStagedAndUntracked() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try write("staged\n", to: root, "staged.txt")
        _ = try await git(["add", "staged.txt"], at: root)
        try write("untracked\n", to: root, "untracked.txt")
        let diff = try await WorkspaceDiffEngine.generate(base: .head, workspace: root.path)
        XCTAssertNil(diff.error, "A repository with no commits must not error")
        let byPath = Dictionary(uniqueKeysWithValues: diff.files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["staged.txt"]?.status, "added")
        XCTAssertEqual(byPath["staged.txt"]?.additions, 1)
        XCTAssertEqual(byPath["untracked.txt"]?.status, "untracked")
        XCTAssertEqual(byPath["untracked.txt"]?.additions, 1)
    }

    // MARK: - Path base / scoping

    func testSubdirectoryWorkspaceUsesWorkspaceRelativePaths() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try write("one\n", to: sub, "a.txt")
        try write("outside\n", to: root, "outside.txt")
        _ = try await git(["add", "."], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try write("two\n", to: sub, "a.txt")
        try write("changed\n", to: root, "outside.txt")
        try write("fresh\n", to: sub, "new.txt")
        let diff = try await WorkspaceDiffEngine.generate(base: .head, workspace: sub.path)
        XCTAssertEqual(Set(diff.files.map(\.path)), ["a.txt", "new.txt"],
                       "Paths resolve within the workspace; files outside it are excluded")
        XCTAssertEqual(diff.files.first { $0.path == "a.txt" }?.additions, 1)
        XCTAssertEqual(diff.files.first { $0.path == "new.txt" }?.status, "untracked")
    }

    func testRenameUnderDirectoryKeepsFullPath() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try write("x\n", to: root, "a/old.txt")
        _ = try await git(["add", "."], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        _ = try await git(["mv", "a/old.txt", "a/new.txt"], at: root)
        let diff = try await WorkspaceDiffEngine.generate(base: .staged, workspace: root.path)
        let file = try XCTUnwrap(diff.files.first { $0.status == "renamed" })
        XCTAssertEqual(file.path, "a/new.txt", "A rename keeps the full path, not a stripped one")
        XCTAssertEqual(file.oldPath, "a/old.txt")
    }

    func testSpacedAndQuotedPathsResolve() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        let weird = "tab\tname.txt"
        try write("one\n", to: root, "my file.txt")
        try write("one\n", to: root, weird)
        _ = try await git(["add", "."], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        try write("two\n", to: root, "my file.txt")
        try write("two\n", to: root, weird)
        let diff = try await WorkspaceDiffEngine.generate(base: .worktree, workspace: root.path)
        XCTAssertEqual(Set(diff.files.map(\.path)), ["my file.txt", weird])
        for file in diff.files { XCTAssertEqual(file.additions, 1) }
    }

    func testTopLevelBDirectoryKeepsPrefixForBinaryModeAndEmpty() async throws {
        let root = try await makeRepo(); defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: nested.appendingPathComponent("x.bin"))
        try write("stable\n", to: nested, "mode.txt")
        _ = try await git(["add", "."], at: root)
        _ = try await git(["commit", "-qm", "init"], at: root)
        // A binary change, an executable-bit-only change and a staged empty add
        // emit no `---`/`+++` lines, so the `diff --git` header is the only path
        // source. A real top-level `b/` component must survive intact.
        try Data([0, 9, 9, 9]).write(to: nested.appendingPathComponent("x.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: nested.appendingPathComponent("mode.txt").path)
        try Data().write(to: nested.appendingPathComponent("newempty.txt"))
        _ = try await git(["add", "b/newempty.txt"], at: root)
        let diff = try await WorkspaceDiffEngine.generate(base: .head, workspace: root.path)
        XCTAssertNil(diff.error)
        XCTAssertEqual(Set(diff.files.map(\.path)), ["b/x.bin", "b/mode.txt", "b/newempty.txt"],
                       "A path under a top-level `b/` directory must not lose its first component")
        let binary = try XCTUnwrap(diff.files.first { $0.path == "b/x.bin" })
        XCTAssertTrue(binary.binary)
        XCTAssertNil(binary.oldPath, "An in-place binary change has no rename source")
        let mode = try XCTUnwrap(diff.files.first { $0.path == "b/mode.txt" })
        XCTAssertNil(mode.oldPath, "A mode-only change keeps the same path")
        let empty = try XCTUnwrap(diff.files.first { $0.path == "b/newempty.txt" })
        XCTAssertEqual(empty.status, "added")
        XCTAssertNil(empty.oldPath, "An empty new file has no old path")
    }

    func testUnbornHeadResolvesEmptyTreeForSHA256Repository() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let initBlock = try await git(["init", "-q", "-b", "main", "--object-format=sha256"], at: dir)
        guard initBlock.exitCode == 0 else { throw XCTSkip("git lacks --object-format=sha256") }
        _ = try await git(["config", "user.email", "fixture@example.com"], at: dir)
        _ = try await git(["config", "user.name", "Fixture"], at: dir)
        try write("staged\n", to: dir, "staged.txt")
        _ = try await git(["add", "staged.txt"], at: dir)
        let diff = try await WorkspaceDiffEngine.generate(base: .head, workspace: dir.path)
        XCTAssertNil(diff.error, "A SHA-256 repository needs its own empty tree, not the SHA-1 one")
        let file = try XCTUnwrap(diff.files.first { $0.path == "staged.txt" })
        XCTAssertEqual(file.status, "added")
        XCTAssertEqual(file.additions, 1)
    }
}
