import Foundation

struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }
    var headers: [String]
    var alignments: [Alignment]
    var rows: [[String]]
}
enum MarkdownBlock: Equatable {
    case text(String)
    case table(MarkdownTable)
}
enum MarkdownBlocks {
    static func cells(_ line: String) -> [String]? {
        let line = line.trimmingCharacters(in: .whitespaces)
        var result: [String] = [], cell = "", escaped = false, separators = 0
        for c in line {
            if escaped { cell.append(c); escaped = false; continue }
            if c == "\\" { cell.append(c); escaped = true; continue }
            if c == "|" { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""; separators += 1 }
            else { cell.append(c) }
        }
        guard separators > 0 else { return nil }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        if line.hasPrefix("|") { result.removeFirst() }
        if result.last == "", line.hasSuffix("|") { result.removeLast() }
        return result
    }
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = [], text: [String] = [], i = 0
        var fence: (Character, Int)?
        func flush() {
            let joined = text.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.text(joined)) }
            text = []
        }
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if let current = fence {
                        if current.0 == first && count >= current.1 && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    } else { fence = (first, count) }
                    text.append(line); i += 1; continue
                }
            }
            if fence == nil, !line.hasPrefix("    "), !line.hasPrefix("\t"), i + 1 < lines.count,
               let headers = cells(line), !headers.isEmpty, let separators = cells(lines[i + 1]),
               headers.count == separators.count,
               separators.allSatisfy({ $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }) {
                flush()
                let alignments: [MarkdownTable.Alignment] = separators.map {
                    $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .trailing) : .leading
                }
                i += 2
                var rows: [[String]] = []
                while i < lines.count, !lines[i].hasPrefix("    "), !lines[i].hasPrefix("\t"), let cells = cells(lines[i]), !cells.isEmpty {
                    rows.append(Array((cells + Array(repeating: "", count: headers.count)).prefix(headers.count)))
                    i += 1
                }
                blocks.append(.table(.init(headers: headers, alignments: alignments, rows: rows)))
            } else { text.append(line); i += 1 }
        }
        flush(); return blocks
    }
}
