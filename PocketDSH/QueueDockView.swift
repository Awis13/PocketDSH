import SwiftUI

/// Pending native session queue: visible, editable, steerable and removable.
/// Capability-gated by the `session.queue.v1` handshake, so an older host shows
/// nothing and no control can enable an operation the host would reject.
struct QueueDockView: View {
    @EnvironmentObject private var store: PocketStore
    @Environment(\.harnessTheme) private var theme
    @State private var editing: NativeQueueItem?
    @State private var editText = ""
    @State private var loadingEdit = false
    @State private var busy = false

    private var visible: Bool {
        store.usesNativeHarness && store.nativeSupportsQueue && !store.nativeQueue.isEmpty
    }

    var body: some View {
        if visible {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle.portrait").foregroundStyle(theme.accent)
                    Text(store.nativeQueue.count == 1 ? "1 queued request" : "\(store.nativeQueue.count) queued requests")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                }
                ForEach(store.nativeQueue) { item in row(item) }
                if store.nativeQueueOmitted > 0 {
                    Text("+\(store.nativeQueueOmitted) more not shown").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.accent.opacity(0.20), lineWidth: 1))
            .accessibilityIdentifier("nativeQueueDock")
            .sheet(item: $editing) { item in editor(item) }
        }
    }

    @ViewBuilder private func row(_ item: NativeQueueItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.isSteering ? "arrow.turn.down.right" : "clock")
                .font(.caption)
                .foregroundStyle(item.isSteering ? theme.accent : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.isEmpty ? "Queued request" : item.preview)
                    .font(.system(size: 13)).lineLimit(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.truncated ? item.placementLabel + " · preview shortened" : item.placementLabel)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Menu {
                Button("Edit", systemImage: "pencil") { beginEditing(item) }
                    .disabled(!store.canControlQueue)
                if !item.isSteering {
                    Button("Steer current turn", systemImage: "arrow.turn.down.right") {
                        act { await store.steerQueued(item.id) }
                    }.disabled(!store.canControlQueue)
                }
                Button(role: .destructive) { act { await store.removeQueued(item.id) } } label: {
                    Label("Remove", systemImage: "trash")
                }.disabled(!store.canControlQueue)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18)).frame(width: 44, height: 36)
            }
            .accessibilityLabel("Actions for queued request")
        }
    }

    private func beginEditing(_ item: NativeQueueItem) {
        guard store.canControlQueue else { return }
        editing = item
        guard item.truncated else {
            loadingEdit = false
            editText = item.preview
            return
        }
        // The preview was clipped; fetch the bounded full text for this one item.
        loadingEdit = true
        editText = ""
        store.loadQueuedText(item.id) { text in
            editText = text
            loadingEdit = false
        }
    }

    private func act(_ work: @escaping () async -> Void) {
        guard !busy, store.canControlQueue else { return }
        busy = true
        Task { await work(); busy = false }
    }

    private func editor(_ item: NativeQueueItem) -> some View {
        NavigationStack {
            Form {
                Section {
                    if loadingEdit { ProgressView().controlSize(.small) }
                    TextField("Request text", text: $editText, axis: .vertical).lineLimit(3...12)
                        .accessibilityIdentifier("queueEditField")
                } header: { Text("Edit queued request") } footer: {
                    Text(item.truncated
                        ? "The stored request is longer than the preview; edit the full text below."
                        : "Replacing the text keeps this request's position and delivery mode.")
                }
            }
            .navigationTitle("Edit request").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil; loadingEdit = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let id = item.id, text = editText
                        editing = nil; loadingEdit = false
                        Task { await store.editQueued(id, prompt: text) }
                    }.disabled(loadingEdit || editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canControlQueue)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
