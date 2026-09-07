import Foundation
@main struct MarkdownChecks {
    static func main() {
        let source = "Intro\n\n| Day | Weather | T° | Rain |\n|---|:---:|---:|---|\n| Mon | **Fog** | 7…22 | 0 mm |\n| Tue | Rain | 15…24 |\n\nEnd"
        let blocks = MarkdownBlocks.parse(source)
        assert(blocks.count == 3)
        guard case .table(let table) = blocks[1] else { fatalError("Missing table") }
        assert(table.headers == ["Day", "Weather", "T°", "Rain"])
        assert(table.alignments == [.leading, .center, .trailing, .leading])
        assert(table.rows[1] == ["Tue", "Rain", "15…24", ""])
        assert(MarkdownBlocks.cells(#"| a\|b | c |"#) == [#"a\|b"#, "c"])
        assert(MarkdownBlocks.cells("a | b") == ["a", "b"])
        assert(MarkdownBlocks.parse("```md\n" + source + "\n```").count == 1)
        assert(MarkdownBlocks.parse("    | a | b |\n    |---|---|").count == 1)
        assert(MarkdownBlocks.parse("| a | b |\n|---|\n| c | d |").count == 1)
        assert(MarkdownBlocks.parse(source.replacingOccurrences(of: "\n", with: "\r\n")) == blocks)
        for i in source.indices { _ = MarkdownBlocks.parse(String(source[..<i])) }
        print("PASS: table alignment, padding, escaped pipes, optional borders, fenced and indented code, malformed tables, CRLF, streaming prefixes")
    }
}
