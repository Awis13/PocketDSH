import SwiftUI

/// The two presentations read the same session metadata from PocketStore.
struct ContextStatusView: View {
    @EnvironmentObject private var store: PocketStore
    @Environment(\.harnessTheme) private var theme
    @State private var showingDetails = false
    private var latest: NativeRequestInfo? { store.nativeRequests.last }

    var body: some View {
        Button { showingDetails = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(theme.accent)
                Text(latest?.contextLabel ?? "Context —").monospacedDigit().lineLimit(1)
                if let fraction = latest?.fraction {
                    ProgressView(value: min(1, max(0, fraction)))
                        .tint(fraction > 0.9 ? .orange : theme.accent).frame(width: 50)
                        .accessibilityLabel("Input plus output reserve")
                }
                Spacer(minLength: 4)
                if !store.nativeProtocolNotices.isEmpty { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                Text(latest?.stageLabel ?? "Request details").lineLimit(1).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.caption).padding(.horizontal, 20).padding(.vertical, 9)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("contextStatus")
            .accessibilityLabel("Context and request details")
            .sheet(isPresented: $showingDetails) {
                ContextRequestInspector().environmentObject(store)
            }
            .onChange(of: store.selectedID) { _, _ in showingDetails = false }
    }
}

private struct ContextRequestInspector: View {
    @EnvironmentObject private var store: PocketStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    private var request: NativeRequestInfo? {
        store.nativeRequests.first(where: { $0.id == selected }) ?? store.nativeRequests.last
    }
    var body: some View {
        NavigationStack {
            Form {
                if let request {
                    Section("Request") {
                        if store.nativeRequests.count > 1 {
                            Picker("Inspect", selection: Binding(get: { selected ?? "" }, set: { selected = $0.isEmpty ? nil : $0 })) {
                                Text("Latest request").tag("")
                                ForEach(store.nativeRequests.dropLast().reversed()) { entry in
                                    Text(entry.stageLabel + " · " + String(entry.id.prefix(8))).tag(entry.id)
                                }
                            }
                        }
                        field("Status", request.stageLabel)
                        field("Purpose", request.string("purpose") ?? "Unknown")
                        field("Request ID", request.id)
                        field("Turn ID", request.turnID ?? "Unknown")
                        if let code = request.string("code") { field("Result code", code) }
                    }
                    Section {
                        field("Input", request.inputTokens.map { "\($0.formatted()) · \(request.inputKind)" } ?? "Unknown")
                        field("Count source", request.string("budget.input.source") ?? "Unknown")
                        field("Capacity", request.capacity.map { $0.formatted() } ?? "Unknown")
                        field("Capacity source", request.string("budget.capabilities.capacity.source") ?? "Unknown")
                        field("Output reserve", request.reserve.map { $0.formatted() } ?? "Unknown")
                        field("Remaining after reserve", request.remaining.map { $0.formatted() } ?? "Unknown")
                        field("Server counting", request.string("budget.capabilities.inputCounting") ?? "Unknown")
                        if let code = request.string("budget.countIssue") { field("Counting note", code) }
                    } header: { Text("Context budget") } footer: {
                        Text("The bar includes input and the output reserve. Estimated counts are approximate. Unknown capacity stays unknown.")
                    }
                    Section {
                        count("Prompt tokens", "usage.promptTokens", request)
                        count("Completion tokens", "usage.completionTokens", request)
                        count("Total tokens", "usage.totalTokens", request)
                        count("Cached prompt tokens", "usage.cachedTokens", request)
                        count("Reasoning tokens", "usage.reasoningTokens", request)
                    } header: { Text("Provider usage") } footer: {
                        Text("Cached and reasoning tokens are subsets, not extra tokens. Missing provider fields are not zero.")
                    }
                    Section {
                        time("Preparation", "preparationMS", request)
                        time("Token measurement", "measurementMS", request)
                        time("Response headers", "responseHeadersMS", request)
                        time("First data", "firstDataMS", request)
                        time("First reasoning", "firstReasoningMS", request)
                        time("First text", "firstTextMS", request)
                        time("Model response finished", "modelCompletedMS", request)
                        time("Request elapsed", "elapsedMS", request)
                    } header: { Text("Observed timing") } footer: {
                        Text("Response timings start when the host dispatches the request. They include transport delays and do not measure server prefill progress or cache hits. Elapsed time updates at observed stages.")
                    }
                    Section {
                        ShareLink(item: request.diagnosticExport) { Label("Share request diagnostics", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("shareRequestDiagnostics")
                    } footer: { Text("Metadata only: no endpoint, credentials, prompt, reasoning or tool output.") }
                } else {
                    Section {
                        Text("No request metadata yet").font(.headline)
                        Text("Send a request with a compatible Native Harness host. Older sessions and hosts may not provide these diagnostics.").foregroundStyle(.secondary)
                    }
                }
                if !store.nativeProtocolNotices.isEmpty {
                    Section("Protocol notes") {
                        ForEach(store.nativeProtocolNotices, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
            }.navigationTitle("Request details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .accessibilityIdentifier("requestInspector")
        }.presentationDetents([.large])
    }
    private func field(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(NativeRequestInfo.label(value)).monospacedDigit().textSelection(.enabled).multilineTextAlignment(.trailing) }
    }
    private func count(_ title: String, _ key: String, _ r: NativeRequestInfo) -> some View {
        field(title, r.tokens(key).map { $0.formatted() } ?? "Not reported")
    }
    private func time(_ title: String, _ key: String, _ r: NativeRequestInfo) -> some View {
        field(title, r.milliseconds(key).map { $0 < 1000 ? String(format: "%.0f ms", $0) : String(format: "%.2f s", $0 / 1000) } ?? "Not observed")
    }
}
