import SwiftUI
import UIKit

struct AssistantMarkdown: View {
    @Environment(\.harnessTheme) private var theme
    let text: String
    var terminal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(.init(text)).font(.system(size: theme.messageSize, design: terminal ? .monospaced : theme.design)).lineSpacing(5).textSelection(.enabled).modifier(HarnessTextLegibility())
                case .table(let table): MarkdownTableView(table: table, terminal: terminal)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct MarkdownTableView: View {
    @Environment(\.harnessTheme) private var theme
    @ScaledMetric private var scale: CGFloat = 1
    let table: MarkdownTable
    var terminal = false
    private func width(_ column: Int) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        let measured = ([table.headers] + table.rows).map { ($0[column] as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(240, max(90, ceil(measured) + 28)) * scale
    }
    private func alignment(_ column: Int) -> Alignment {
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
    private func row(_ cells: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { column in
                Text(.init(cells[column]))
                    .font(.system(size: 14 * scale, weight: header ? .semibold : .regular, design: terminal ? .monospaced : theme.design))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width(column) - 24, alignment: alignment(column))
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .overlay(alignment: .trailing) { if column < cells.count - 1 { Rectangle().fill(theme.accent.opacity(0.10)).frame(width: 1) } }
                    .accessibilityLabel(header ? cells[column] : table.headers[column] + ": " + cells[column])
            }
        }.accessibilityElement(children: .combine)
    }
    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.headers, header: true).background(theme.accent.opacity(0.14))
                ForEach(table.rows.indices, id: \.self) { index in
                    Divider()
                    row(table.rows[index], header: false)
                        .background(index.isMultiple(of: 2) ? theme.surface.opacity(0.65) : Color.clear)
                }
            }.fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: table.headers.indices.reduce(CGFloat(0)) { $0 + width($1) }, alignment: .leading)
        .background(theme.surface.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: terminal ? 3 : 12))
        .overlay(RoundedRectangle(cornerRadius: terminal ? 3 : 12).stroke(theme.accent.opacity(0.18), lineWidth: 1))
        .accessibilityIdentifier("markdownTable")
    }
}
