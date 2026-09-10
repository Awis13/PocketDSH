import Foundation

/// One inline hunk for a tool-driven file edit, in the shape the Chat renderer
/// already understands: `oldText` is the replaced region (`nil` for a pure
/// insertion) and `newText` is the replacement, both carrying `contextLines`
/// lines of surrounding context. This is the native analogue of the DSH inline
/// diff and is deliberately separate from `WorkspaceDiffHunk` (the
/// `workspace.diff.v1` projection) so neither contract can drift into the other.
public struct ToolDiffHunk: Sendable, Equatable {
    public var path: String
    public var oldText: String?
    public var newText: String
    public init(path: String, oldText: String?, newText: String) {
        self.path = path; self.oldText = oldText; self.newText = newText
    }
}

/// Hard bounds for a single tool result's inline diff. The workspace diff has
/// its own limits; this stays independent so a large edit can never inflate a
/// tool-result frame past the presentation budget.
public enum ToolDiffLimits {
    public static let contextLines = 3
    public static let maximumHunks = 200
    public static let maximumLines = 300
    public static let maximumFieldBytes = 16_384
    public static let maximumTotalBytes = 262_144
    /// LCS table cells before a region is coalesced into one replacement. Local
    /// edits trim to a small middle; this only bounds a full-file rewrite.
    static let maximumDiffCells = 4_000_000
}

/// Pure line differ for inline tool diffs. It never touches the filesystem and
/// never throws: `edit_file` has both the before and after text in scope and
/// only needs a bounded, renderable projection.
public enum ToolDiff {
    /// One hunk per changed region, with `contextLines` of context on each side
    /// of the region. A hunk whose changed region only adds lines has a `nil`
    /// `oldText` so the renderer can label it an insertion.
    public static func hunks(path: String, before: String, after: String) -> [ToolDiffHunk] {
        guard before != after else { return [] }
        let ops = diffOps(lines(before), lines(after))
        let changed = ops.indices.filter { !isEqual(ops[$0]) }
        // A raw-text difference that vanishes at line granularity (a trailing
        // newline added or removed) yields no changed ops and is intentionally
        // not rendered: it has no lines to show and forcing a hunk would
        // destabilize the context grouping for no reader value.
        guard !changed.isEmpty else { return [] }

        var groups: [(first: Int, last: Int)] = []
        for change in changed {
            if let previous = groups.last, change - previous.last <= ToolDiffLimits.contextLines * 2 + 1 {
                groups[groups.count - 1].last = change
            } else {
                groups.append((change, change))
            }
        }

        var result: [ToolDiffHunk] = []
        var totalBytes = 0
        for group in groups {
            guard result.count < ToolDiffLimits.maximumHunks else { break }
            let lower = max(0, group.first - ToolDiffLimits.contextLines)
            let upper = min(ops.count - 1, group.last + ToolDiffLimits.contextLines)
            let hunk = makeHunk(path: path, ops: ops[lower...upper])
            let size = (hunk.oldText?.utf8.count ?? 0) + hunk.newText.utf8.count
            guard totalBytes + size <= ToolDiffLimits.maximumTotalBytes else { break }
            totalBytes += size
            result.append(hunk)
        }
        return result
    }

    private enum DiffOp {
        case equal(String), delete(String), insert(String)
    }

    private static func isEqual(_ op: DiffOp) -> Bool {
        if case .equal = op { return true }
        return false
    }

    /// Splits on newlines, dropping the trailing empty element a final newline
    /// produces so line counts and context match what a reader sees.
    static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func diffOps(_ old: [String], _ new: [String]) -> [DiffOp] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        var ops: [DiffOp] = []
        ops.reserveCapacity(max(old.count, new.count))
        for line in old[0..<prefix] { ops.append(.equal(line)) }
        ops.append(contentsOf: middleOps(Array(old[prefix..<(old.count - suffix)]),
                                         Array(new[prefix..<(new.count - suffix)])))
        if suffix > 0 { for line in old[(old.count - suffix)...] { ops.append(.equal(line)) } }
        return ops
    }

    private static func middleOps(_ old: [String], _ new: [String]) -> [DiffOp] {
        if old.isEmpty { return new.map { .insert($0) } }
        if new.isEmpty { return old.map { .delete($0) } }
        guard old.count * new.count <= ToolDiffLimits.maximumDiffCells else {
            return old.map { .delete($0) } + new.map { .insert($0) }
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        var i = old.count - 1
        while i >= 0 {
            var j = new.count - 1
            while j >= 0 {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                j -= 1
            }
            i -= 1
        }
        var ops: [DiffOp] = []
        var x = 0, y = 0
        while x < old.count, y < new.count {
            if old[x] == new[y] { ops.append(.equal(old[x])); x += 1; y += 1 }
            else if table[x + 1][y] >= table[x][y + 1] { ops.append(.delete(old[x])); x += 1 }
            else { ops.append(.insert(new[y])); y += 1 }
        }
        while x < old.count { ops.append(.delete(old[x])); x += 1 }
        while y < new.count { ops.append(.insert(new[y])); y += 1 }
        return ops
    }

    private static func makeHunk(path: String, ops: ArraySlice<DiffOp>) -> ToolDiffHunk {
        var old: [String] = [], new: [String] = []
        var removed = false
        for op in ops {
            switch op {
            case .equal(let line): old.append(line); new.append(line)
            case .delete(let line): old.append(line); removed = true
            case .insert(let line): new.append(line)
            }
        }
        // `oldText = nil` for a pure insertion is intentional: it matches the
        // documented DSH `FileDiff` contract and gives the existing
        // `ToolDiffView` a clean insertion card. (DSH's `computeHunkDiffs` JS
        // historically also carried context on the old side, so this is the
        // native contract, not a byte-for-byte clone of that implementation.)
        return ToolDiffHunk(path: path, oldText: removed ? clamp(old) : nil, newText: clamp(new))
    }

    /// Clamps a field by line count, then bytes. The renderer re-clamps too, but
    /// the host must never emit an unbounded hunk.
    private static func clamp(_ lines: [String]) -> String {
        let bounded = lines.count > ToolDiffLimits.maximumLines ? Array(lines.prefix(ToolDiffLimits.maximumLines)) : lines
        let text = bounded.joined(separator: "\n")
        return text.utf8.count > ToolDiffLimits.maximumFieldBytes ? prefix(text, bytes: ToolDiffLimits.maximumFieldBytes) : text
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        var end = text.startIndex, count = 0
        while end < text.endIndex {
            let next = text.index(after: end), size = text[end..<next].utf8.count
            guard count + size <= bytes else { break }
            count += size; end = next
        }
        return String(text[..<end])
    }
}
