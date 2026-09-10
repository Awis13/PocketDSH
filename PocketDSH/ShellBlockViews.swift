import SwiftUI
import UIKit

/// Reveal the active text range through both nested scroll views: horizontal
/// command output and the vertical transcript. A SwiftUI reader cannot address
/// a line owned by the nested horizontal reader from the outer transcript.
private struct ShellMatchScrollAnchor: UIViewRepresentable {
    let request: String
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) { view.request(request) }
    final class Anchor: UIView {
        private var revision: String?
        private var pending = false
        func request(_ value: String) {
            guard revision != value else { return }
            revision = value; pending = true
            DispatchQueue.main.async { [weak self] in self?.reveal() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            if pending { DispatchQueue.main.async { [weak self] in self?.reveal() } }
        }
        private func reveal() {
            guard pending, window != nil, !bounds.isEmpty else { return }
            pending = false
            var parent = superview
            while let view = parent {
                if let scroll = view as? UIScrollView {
                    scroll.layoutIfNeeded()
                    scroll.scrollRectToVisible(convert(bounds, to: scroll).insetBy(dx: -12, dy: -8), animated: false)
                }
                parent = view.superview
            }
        }
    }
}

struct ShellSentContext: View {
    let text: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Label("Attached terminal context", systemImage: "paperclip").font(.caption).frame(minHeight: 44) }
            .buttonStyle(.plain).sheet(isPresented: $showing) {
                NavigationStack {
                    ScrollView { Text(text).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                        .navigationTitle("Sent terminal context")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showing = false } } }
                }
            }
    }
}

struct ShellAttachmentStrip: View {
    @EnvironmentObject private var store: PocketStore
    @Environment(\.harnessTheme) private var theme
    @State private var preview: ShellContextAttachment?
    @State private var diffPreview: ShellDiffAttachment?
    var body: some View {
        if !store.shellAttachments.isEmpty || !store.shellDiffAttachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(store.shellAttachments) { attachment in
                        HStack(spacing: 2) {
                            Button { preview = attachment } label: {
                                Label(attachment.command, systemImage: "terminal")
                                    .lineLimit(1).frame(maxWidth: 230).padding(.horizontal, 10).frame(minHeight: 44)
                            }.accessibilityLabel("Preview attached block: " + attachment.command)
                            Button { store.shellAttachments.removeAll { $0.id == attachment.id } } label: {
                                Image(systemName: "xmark").frame(width: 44, height: 44)
                            }.accessibilityLabel("Remove attached block: " + attachment.command)
                        }.background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(store.shellDiffAttachments) { attachment in
                        HStack(spacing: 2) {
                            Button { diffPreview = attachment } label: {
                                Label(attachment.path, systemImage: "plus.forwardslash.minus")
                                    .lineLimit(1).frame(maxWidth: 230).padding(.horizontal, 10).frame(minHeight: 44)
                            }.accessibilityLabel("Preview attached diff: " + attachment.path)
                            Button { store.shellDiffAttachments.removeAll { $0.id == attachment.id } } label: {
                                Image(systemName: "xmark").frame(width: 44, height: 44)
                            }.accessibilityLabel("Remove attached diff: " + attachment.path)
                        }.background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.scrollIndicators(.hidden).font(.caption.monospaced()).buttonStyle(.plain)
                .accessibilityIdentifier("shellAttachments")
                .sheet(item: $diffPreview) { attachment in
                    NavigationStack {
                        ScrollView { Text(attachment.readable).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                            .navigationTitle("Attached diff")
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { diffPreview = nil } } }
                    }.tint(theme.accent)
                }
                .sheet(item: $preview) { attachment in
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(attachment.command).font(.headline.monospaced())
                                Text(attachment.directory).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(attachment.running ? "Snapshot captured while running" : attachment.exitCode.map { "Exit \($0)" } ?? "Exit unknown").font(.caption)
                                if attachment.clipped { Text("Clipped excerpt · last 4 KiB of output at most").font(.caption).foregroundStyle(.orange) }
                                Text(attachment.output.isEmpty ? "No output" : attachment.output).font(.body.monospaced())
                            }.frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled)
                        }.navigationTitle("Attached terminal context")
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { preview = nil } } }
                    }.tint(theme.accent)
                }
        }
    }
}

/// Only mounted while Find is open. Normal output keeps its existing compact renderer.
struct ShellFindOutput: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.harnessTheme) private var theme
    let block: NativeBlock
    let search: ShellBlockSearch
    let activeMatch: ShellSearchMatch?
    let revision: Int
    private var matchID: String { "shell-match-\(block.id)-\(activeMatch?.line ?? -1)-\(activeMatch?.range.location ?? -1)-\(activeMatch?.range.length ?? 0)-\(revision)" }
    private var styledLines: [AttributedString] {
        let value = block.attributedOutput(appearance: TerminalAppearance(theme: theme, scheme: scheme))
        return value.characters.split(separator: "\n", omittingEmptySubsequences: false).map { AttributedString(value[$0.startIndex..<$0.endIndex]) }
    }
    var body: some View {
        let lines = styledLines
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(search.lines.indices, id: \.self) { index in
                    line(index, styled: lines.indices.contains(index) ? lines[index] : AttributedString(search.lines[index]))
                }
            }.font(Font(TerminalAppearance.font(size: theme.messageSize))).fontDesign(nil)
                .fixedSize(horizontal: true, vertical: true).textSelection(.enabled)
        }.scrollIndicators(.hidden)
    }
    private func range(_ match: ShellSearchMatch, in value: AttributedString) -> Range<AttributedString.Index>? {
        let plain = String(value.characters)
        guard let range = Range(match.range, in: plain),
              let start = AttributedString.Index(range.lowerBound, within: value),
              let end = AttributedString.Index(range.upperBound, within: value) else { return nil }
        return start..<end
    }
    @ViewBuilder private func line(_ index: Int, styled: AttributedString) -> some View {
        let value = highlighted(styled, line: index)
        if let activeMatch, activeMatch.line == index, let r = range(activeMatch, in: value) {
            HStack(spacing: 0) {
                Text(AttributedString(value[value.startIndex..<r.lowerBound]))
                Text(AttributedString(value[r])).background(ShellMatchScrollAnchor(request: matchID).allowsHitTesting(false).accessibilityHidden(true))
                Text(AttributedString(value[r.upperBound..<value.endIndex]))
            }.accessibilityElement(children: .combine).accessibilityLabel("Match, line \(index + 1): " + search.lines[index])
        } else { Text(value.characters.isEmpty ? AttributedString(" ") : value) }
    }
    private func highlighted(_ input: AttributedString, line: Int) -> AttributedString {
        var value = input
        for match in search.matches where match.line == line {
            if let r = range(match, in: value) {
                value[r].backgroundColor = match == activeMatch ? Color.yellow : theme.accent.opacity(0.3)
                if match == activeMatch { value[r].foregroundColor = .black }
            }
        }
        return value
    }
}
