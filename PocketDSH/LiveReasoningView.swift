import SwiftUI

/// A bounded window onto the newest host-provided reasoning, without expanding the transcript.
struct LiveReasoningView: View {
    @Environment(\.harnessTheme) private var theme
    let text: String
    var compact = false
    var terminal = false
    @State private var expanded = false
    private var tail: String { String(text.suffix(1200)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !compact { HStack(spacing: 7) {
                ProgressView().controlSize(.mini).tint(theme.accent)
                Text("Thinking").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.accent)
            }
            }
            Button { expanded.toggle() } label: {
                HStack {
                    Text(expanded ? "Hide reasoning" : "Show reasoning")
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }.font(.system(size: 11, design: terminal ? .monospaced : .default))
                    .foregroundStyle(theme.accent).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("toggleLiveReasoning")
            if expanded {
                Text(text).font(.system(size: 12, design: terminal ? .monospaced : .default))
                    .lineSpacing(3).foregroundStyle(theme.ink.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tail).font(.system(size: 12, design: terminal ? .monospaced : .default)).lineSpacing(3)
                            .foregroundStyle(theme.ink.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("reasoning-tail")
                    }
                }.frame(height: compact ? 34 : 58).scrollIndicators(.hidden).defaultScrollAnchor(.bottom)
                    .onChange(of: tail) { _, _ in proxy.scrollTo("reasoning-tail", anchor: .bottom) }
            }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 11)
            .background(theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: terminal ? 4 : 17))
            .overlay { RoundedRectangle(cornerRadius: terminal ? 4 : 17).strokeBorder(theme.accent.opacity(0.14), lineWidth: 0.5) }
            .accessibilityIdentifier("liveReasoning")
    }
}
