import Foundation

/// Read-only view of the workspace working tree, index or a branch relative to
/// HEAD. The host computes it; the client only renders it. Every field is
/// bounded so a hostile or enormous repository cannot grow a single frame past
/// the wire budget.
public struct WorkspaceDiffHunk: Codable, Sendable, Equatable {
    public var path: String
    public var header: String
    public var oldText: String
    public var newText: String
    public init(path: String, header: String, oldText: String, newText: String) {
        self.path = path; self.header = header; self.oldText = oldText; self.newText = newText
    }
}

public struct WorkspaceDiffFile: Codable, Sendable, Equatable {
    public var path: String
    public var oldPath: String?
    public var status: String
    public var binary: Bool
    public var additions: Int
    public var deletions: Int
    public var truncated: Bool
    public var hunks: [WorkspaceDiffHunk]
    public init(path: String, oldPath: String? = nil, status: String, binary: Bool = false,
                additions: Int = 0, deletions: Int = 0, truncated: Bool = false, hunks: [WorkspaceDiffHunk] = []) {
        self.path = path; self.oldPath = oldPath; self.status = status; self.binary = binary
        self.additions = additions; self.deletions = deletions; self.truncated = truncated; self.hunks = hunks
    }
}

public struct WorkspaceDiff: Codable, Sendable, Equatable {
    public var base: String
    public var resolvedBase: String?
    public var files: [WorkspaceDiffFile]
    public var truncated: Bool
    public var error: String?
    public init(base: String, resolvedBase: String? = nil, files: [WorkspaceDiffFile] = [],
                truncated: Bool = false, error: String? = nil) {
        self.base = base; self.resolvedBase = resolvedBase; self.files = files
        self.truncated = truncated; self.error = error
    }
}

public enum WorkspaceDiffLimits {
    public static let maximumRefBytes = 200
    public static let maximumFiles = 200
    public static let maximumHunksPerFile = 200
    public static let maximumFieldBytes = 16_384
    public static let maximumLines = 300
    public static let maximumFileBytes = 32_768
    public static let maximumTotalBytes = 262_144
}

/// A validated diff base. Arbitrary refs are structural, never free shell text:
/// the runner rejects anything that could be read as an option, a range or an
/// escape before it reaches git.
public enum WorkspaceDiffBase: Sendable, Equatable {
    case worktree
    case staged
    case head
    case ref(String)

    public static let defaultBase = WorkspaceDiffBase.head

    public init?(_ raw: String) {
        switch raw {
        case "worktree": self = .worktree
        case "staged": self = .staged
        case "HEAD": self = .head
        default:
            guard Self.isSafeRef(raw) else { return nil }
            self = .ref(raw)
        }
    }

    public var wireValue: String {
        switch self {
        case .worktree: "worktree"
        case .staged: "staged"
        case .head: "HEAD"
        case .ref(let value): value
        }
    }

    /// Untracked files are part of the working tree, not the index or a commit.
    var includesUntracked: Bool { self == .worktree || self == .head }

    static func isSafeRef(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= WorkspaceDiffLimits.maximumRefBytes,
              !value.contains("\0"), !value.contains(".."), !value.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/@{}~^:+-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public enum WorkspaceDiffEngine {
    private static let diffFlags = ["--no-color", "--no-ext-diff", "--no-textconv", "-M", "--unified=0"]

    public static func generate(base: WorkspaceDiffBase, workspace: String) async throws -> WorkspaceDiff {
        var arguments = ["diff"]
        var resolvedBase: String?
        switch base {
        case .worktree:
            arguments += diffFlags
        case .staged:
            arguments += ["--cached"] + diffFlags
        case .head:
            arguments += ["HEAD"] + diffFlags
        case .ref(let ref):
            guard let common = try await mergeBase(ref: ref, workspace: workspace) else {
                return WorkspaceDiff(base: base.wireValue, resolvedBase: nil, files: [],
                                     truncated: false, error: "This base has no common history with HEAD.")
            }
            resolvedBase = common
            arguments += ["\(common)...HEAD"] + diffFlags
        }
        let block = try await runGit(arguments, workspace: workspace)
        let hitLimit = block.outcome == "outputLimit" || block.outcome == "timedOut" || block.outcome == "cancelled"
        if block.exitCode != 0 && !hitLimit {
            return WorkspaceDiff(base: base.wireValue, resolvedBase: resolvedBase, files: [],
                                 truncated: false, error: failureMessage(block))
        }
        var parser = PatchParser(base: base.wireValue, resolvedBase: resolvedBase)
        var result = parser.parse(block.stdout)
        result.truncated = result.truncated || hitLimit
        if base.includesUntracked {
            await appendUntracked(to: &result, workspace: workspace)
        }
        applyLimits(to: &result)
        return result
    }

    private static func mergeBase(ref: String, workspace: String) async throws -> String? {
        let block = try await runGit(["merge-base", ref, "HEAD"], workspace: workspace, outputLimit: 4096)
        guard block.outcome == "exited", block.exitCode == 0 else { return nil }
        let value = block.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard !value.isEmpty, value.utf8.count <= 128, !value.contains("\n"),
              value.unicodeScalars.allSatisfy({ hexadecimal.contains($0) }) else { return nil }
        return value
    }

    private static func runGit(_ arguments: [String], workspace: String, outputLimit: Int = 1_048_576) async throws -> CommandBlock {
        let command = "git --no-pager -c core.quotePath=false " + arguments.joined(separator: " ")
        return try await ShellRunner.run(command: command, workspace: workspace, timeout: 30, outputLimit: outputLimit)
    }

    private static func failureMessage(_ block: CommandBlock) -> String {
        let text = block.stderr.isEmpty ? block.stdout : block.stderr
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = String(line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200))
        return clean.isEmpty ? "Could not read the git diff for this workspace." : clean
    }

    private static func appendUntracked(to result: inout WorkspaceDiff, workspace: String) async {
        guard result.files.count < WorkspaceDiffLimits.maximumFiles else { result.truncated = true; return }
        guard let listing = try? await runGit(["ls-files", "--others", "--exclude-standard"], workspace: workspace, outputLimit: 262_144),
              listing.outcome == "exited", listing.exitCode == 0 else { return }
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath()
        for line in listing.stdout.components(separatedBy: "\n") where !line.isEmpty {
            guard result.files.count < WorkspaceDiffLimits.maximumFiles else { result.truncated = true; break }
            guard !line.contains("\0") else { continue }
            let file = root.appendingPathComponent(line).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path == root.path || file.path.hasPrefix(root.path + "/") else { continue }
            guard let (data, readTruncated) = readBounded(file, maximum: WorkspaceDiffLimits.maximumFieldBytes) else { continue }
            if data.contains(0) {
                result.files.append(WorkspaceDiffFile(path: line, status: "untracked", binary: true, truncated: readTruncated))
                if readTruncated { result.truncated = true }
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else {
                result.files.append(WorkspaceDiffFile(path: line, status: "untracked", binary: true, truncated: readTruncated))
                if readTruncated { result.truncated = true }
                continue
            }
            let content = text.hasSuffix("\n") ? String(text.dropLast()) : text
            let (clamped, clampedByLines) = clamp(content, maxBytes: WorkspaceDiffLimits.maximumFieldBytes, maxLines: WorkspaceDiffLimits.maximumLines)
            let truncated = readTruncated || clampedByLines
            var entry = WorkspaceDiffFile(path: line, status: "untracked", truncated: truncated,
                                          hunks: [WorkspaceDiffHunk(path: line, header: "", oldText: "", newText: clamped)])
            entry.additions = lineCount(clamped)
            result.files.append(entry)
            if truncated { result.truncated = true }
        }
    }

    private static func readBounded(_ url: URL, maximum: Int) -> (Data, Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximum + 1) else { return nil }
        return data.count > maximum ? (Data(data.prefix(maximum)), true) : (data, false)
    }

    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
    }

    static func clamp(_ text: String, maxBytes: Int, maxLines: Int) -> (String, Bool) {
        var trimmed = false
        var value = text
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines {
            value = lines.prefix(maxLines).joined(separator: "\n")
            trimmed = true
        }
        if value.utf8.count > maxBytes {
            value = prefix(value, bytes: maxBytes)
            trimmed = true
        }
        return (value, trimmed)
    }

    static func prefix(_ text: String, bytes: Int) -> String {
        var end = text.startIndex, count = 0
        while end < text.endIndex {
            let next = text.index(after: end), size = text[end..<next].utf8.count
            guard count + size <= bytes else { break }
            count += size; end = next
        }
        return String(text[..<end])
    }

    private static func applyLimits(to result: inout WorkspaceDiff) {
        var total = 0
        var files: [WorkspaceDiffFile] = []
        for var file in result.files {
            guard files.count < WorkspaceDiffLimits.maximumFiles else { result.truncated = true; break }
            var hunks: [WorkspaceDiffHunk] = []
            var fileBytes = 0
            for var hunk in file.hunks {
                guard hunks.count < WorkspaceDiffLimits.maximumHunksPerFile else { file.truncated = true; break }
                let old = clamp(hunk.oldText, maxBytes: WorkspaceDiffLimits.maximumFieldBytes, maxLines: WorkspaceDiffLimits.maximumLines)
                let new = clamp(hunk.newText, maxBytes: WorkspaceDiffLimits.maximumFieldBytes, maxLines: WorkspaceDiffLimits.maximumLines)
                hunk.oldText = old.0; hunk.newText = new.0
                if old.1 || new.1 { file.truncated = true }
                let size = hunk.oldText.utf8.count + hunk.newText.utf8.count
                guard fileBytes + size <= WorkspaceDiffLimits.maximumFileBytes else { file.truncated = true; break }
                guard total + size <= WorkspaceDiffLimits.maximumTotalBytes else {
                    file.truncated = true; result.truncated = true; break
                }
                fileBytes += size; total += size; hunks.append(hunk)
            }
            file.hunks = hunks
            if file.truncated { result.truncated = true }
            files.append(file)
        }
        result.files = files
    }
}

private struct PatchFileBuilder {
    var path = ""
    var oldPath: String?
    var status = "modified"
    var binary = false
    var truncated = false
    var additions = 0
    var deletions = 0
    var hunks: [WorkspaceDiffHunk] = []
}

private struct PatchParser {
    let base: String
    let resolvedBase: String?
    private var files: [WorkspaceDiffFile] = []
    private var current: PatchFileBuilder?
    private var hunkHeader: String?
    private var hunkOld: [String] = []
    private var hunkNew: [String] = []
    private var minusPath: String?
    private var plusPath: String?
    private var headerOldPath: String?
    private var headerNewPath: String?
    private var sawMinus = false
    private var sawPlus = false

    init(base: String, resolvedBase: String?) {
        self.base = base; self.resolvedBase = resolvedBase
    }

    mutating func parse(_ stdout: String) -> WorkspaceDiff {
        for line in stdout.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                startFile()
                if let paths = Self.headerPaths(line) { headerOldPath = paths.old; headerNewPath = paths.new }
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("new file mode") { current?.status = "added"; continue }
            if line.hasPrefix("deleted file mode") { current?.status = "deleted"; continue }
            if line.hasPrefix("rename from ") { current?.oldPath = String(line.dropFirst("rename from ".count)); current?.status = "renamed"; continue }
            if line.hasPrefix("rename to ") { current?.path = String(line.dropFirst("rename to ".count)); current?.status = "renamed"; continue }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { current?.binary = true; continue }
            if line.hasPrefix("--- ") { sawMinus = true; minusPath = unquote(String(line.dropFirst(4))); continue }
            if line.hasPrefix("+++ ") { sawPlus = true; plusPath = unquote(String(line.dropFirst(4))); continue }
            if line.hasPrefix("@@") { finishHunk(header: line); continue }
            if hunkHeader == nil { continue }
            if line.hasPrefix("+") { hunkNew.append(String(line.dropFirst())) }
            else if line.hasPrefix("-") { hunkOld.append(String(line.dropFirst())) }
        }
        finishHunk(header: nil)
        finishFile()
        return WorkspaceDiff(base: base, resolvedBase: resolvedBase, files: files)
    }

    private mutating func startFile() {
        finishHunk(header: nil)
        finishFile()
        current = PatchFileBuilder()
        hunkHeader = nil; hunkOld = []; hunkNew = []
        minusPath = nil; plusPath = nil; headerOldPath = nil; headerNewPath = nil; sawMinus = false; sawPlus = false
    }

    private mutating func finishHunk(header: String?) {
        if let stored = hunkHeader, var file = current {
            let old = hunkOld.joined(separator: "\n"), new = hunkNew.joined(separator: "\n")
            file.additions += hunkNew.count; file.deletions += hunkOld.count
            file.hunks.append(WorkspaceDiffHunk(path: file.path, header: stored, oldText: old, newText: new))
            current = file
        }
        hunkHeader = header
        hunkOld = []; hunkNew = []
    }

    private mutating func finishFile() {
        guard var file = current else { return }
        if file.path.isEmpty {
            if plusPath != nil { file.path = plusPath! }
            else if minusPath != nil { file.path = minusPath! }
            else if headerNewPath != nil { file.path = headerNewPath! }
            else if headerOldPath != nil { file.path = headerOldPath! }
        }
        if file.oldPath == nil, let headerOldPath, headerOldPath != file.path { file.oldPath = headerOldPath }
        if file.status == "modified" {
            if sawMinus && minusPath == nil && sawPlus { file.status = "added" }
            else if sawPlus && plusPath == nil && sawMinus { file.status = "deleted" }
        }
        if !file.path.isEmpty {
            file.hunks = file.hunks.map { hunk in
                var copy = hunk; copy.path = file.path; return copy
            }
            files.append(WorkspaceDiffFile(path: file.path, oldPath: file.oldPath, status: file.status,
                                           binary: file.binary, additions: file.additions, deletions: file.deletions,
                                           truncated: file.truncated, hunks: file.hunks))
        }
        current = nil
    }

    private func unquote(_ value: String) -> String? {
        var text = value
        if let tab = text.firstIndex(of: "\t") { text = String(text[..<tab]) }
        if text == "/dev/null" { return nil }
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = Self.unescape(String(text.dropFirst().dropLast()))
        }
        if text.hasPrefix("a/") || text.hasPrefix("b/") { text = String(text.dropFirst(2)) }
        return text
    }

    private static func headerPaths(_ line: String) -> (old: String, new: String)? {
        let body = String(line.dropFirst("diff --git ".count))
        guard body.hasPrefix("a/"), let separator = body.range(of: " b/") else { return nil }
        let start = body.index(body.startIndex, offsetBy: 2)
        return (String(body[start..<separator.lowerBound]), String(body[separator.upperBound...]))
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { result.append(character); continue }
            guard let next = iterator.next() else { result.append("\\"); break }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "a": result.append("\u{07}")
            case "b": result.append("\u{08}")
            case "f": result.append("\u{0C}")
            case "v": result.append("\u{0B}")
            default:
                var digits = String(next)
                for _ in 0..<2 { if let digit = iterator.next(), digit.isNumber { digits.append(digit) } }
                if let code = UInt8(digits, radix: 8), let scalar = UnicodeScalar(UInt32(code)) { result.unicodeScalars.append(scalar) }
                else { result.append(next) }
            }
        }
        return result
    }
}
