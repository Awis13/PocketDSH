import SwiftUI

/// Read-only git diff beside the current work. The sheet is transient, so the
/// session, draft and scroll position of the transcript are untouched; it
/// closes itself if the selected session changes.
struct DiffReviewView: View {
    @EnvironmentObject private var store: PocketStore
    @Environment(\.harnessTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var base = "HEAD"
    @State private var customRef = ""

    private let presets: [(id: String, label: String)] = [
        ("worktree", "Working tree"), ("staged", "Staged"), ("HEAD", "HEAD"), ("branch", "Branch")
    ]
    private var effectiveBase: String {
        base == "branch" ? customRef.trimmingCharacters(in: .whitespacesAndNewlines) : base
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Base", selection: $base) {
                    ForEach(presets, id: \.id) { Text($0.label).tag($0.id) }
                }.pickerStyle(.segmented).padding(.horizontal).padding(.top, 8)
                if base == "branch" {
                    HStack(spacing: 8) {
                        TextField("Branch or commit", text: $customRef).textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onSubmit { load() }.accessibilityIdentifier("diffBaseField")
                        Button("Load") { load() }
                            .disabled(customRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.horizontal).padding(.top, 6)
                }
                content
            }
            .navigationTitle("Review changes").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { load() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(store.nativeDiffLoading).accessibilityLabel("Reload diff")
                }
            }
            .onAppear {
                // A reopened sheet must never show the previous base's diff.
                store.nativeDiff = nil
                if base != "branch" { load() }
            }
            .onDisappear { store.nativeDiff = nil }
            .onChange(of: base) { _, _ in
                // The Branch preset waits for the Load button so an empty ref
                // never fires a request.
                if base != "branch" { load() }
            }
            .onChange(of: store.selectedID) { _, _ in dismiss() }
        }
        .frame(minWidth: 340, minHeight: 320)
    }

    private func load() {
        let target = effectiveBase
        guard !target.isEmpty, NativeDiffInfo.isValidBase(target) else {
            if !target.isEmpty { store.error = "Enter a valid base: worktree, staged, HEAD or a branch name." }
            return
        }
        Task { await store.reviewDiff(base: target) }
    }

    @ViewBuilder private var content: some View {
        if store.nativeDiffLoading && store.nativeDiff == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff = store.nativeDiff {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header(diff)
                    if let message = diff.error {
                        notice(message, color: .orange)
                    } else if diff.files.isEmpty {
                        notice("No changes against this base.", color: .secondary)
                    } else {
                        ForEach(Array(diff.files.enumerated()), id: \.offset) { _, file in fileView(file, base: diff.base) }
                    }
                    if diff.truncated {
                        notice("Preview truncated by the host's size limits.", color: .orange)
                    }
                }.padding(16)
            }
        } else if let error = store.error {
            notice(error, color: .orange)
        } else {
            notice("Choose a base to review the current changes.", color: .secondary)
        }
    }

    private func header(_ diff: NativeDiffInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(diff.statusLabel).font(.headline)
            Text(diff.summary).font(.caption).foregroundStyle(.secondary)
            if let resolved = diff.resolvedBase, diff.base != "HEAD" {
                Text("Base \(diff.base) · \(String(resolved.prefix(10)))").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text).font(.callout).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileView(_ file: NativeDiffFile, base: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol(file.status)).foregroundStyle(theme.accent).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.path).font(.system(size: 13, weight: .medium, design: .monospaced)).textSelection(.enabled)
                    if let old = file.oldPath, old != file.path {
                        Text("from \(old)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Text("+\(file.additions)").font(.caption.monospaced()).foregroundStyle(.green)
                Text("−\(file.deletions)").font(.caption.monospaced()).foregroundStyle(.red)
            }
            if file.binary {
                Text("Binary file · not shown").font(.caption).foregroundStyle(.secondary)
            } else if file.hunks.isEmpty {
                Text(file.status == "renamed" ? "Renamed without content changes." : "No textual changes.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in hunkView(hunk, path: file.path, base: base) }
            }
            if file.truncated { Text("This file's preview was truncated.").font(.caption2).foregroundStyle(.orange) }
        }
        .padding(12)
        .background(theme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func hunkView(_ hunk: NativeDiffHunk, path: String, base: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if !hunk.header.isEmpty {
                    Text(hunk.header).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    store.attachDiffAttachment(path: path, header: hunk.header, oldText: hunk.oldText, newText: hunk.newText, base: base)
                } label: {
                    Label("Attach hunk", systemImage: "paperclip").font(.caption)
                }.buttonStyle(.borderless).accessibilityIdentifier("attachDiffHunk")
                    .disabled(store.shellDiffAttachments.count >= 4)
            }
            if !hunk.oldText.isEmpty { code(hunk.oldText, sign: "−", color: .red) }
            if !hunk.newText.isEmpty { code(hunk.newText, sign: "+", color: .green) }
        }
    }

    private func code(_ text: String, sign: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(String(text.prefix(32000)).components(separatedBy: "\n").prefix(300).enumerated()), id: \.offset) { _, line in
                Text(sign + " " + line).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(color)
    }

    private func symbol(_ status: String) -> String {
        switch status {
        case "added", "untracked": return "plus.circle"
        case "deleted": return "minus.circle"
        case "renamed": return "arrow.right.circle"
        default: return "pencil.circle"
        }
    }
}

/// Capability-gated entry point. It owns its own presentation so it can be
/// dropped into either presentation without changing draft or scroll state.
struct DiffReviewButton: View {
    @EnvironmentObject private var store: PocketStore
    @State private var showing = false

    var body: some View {
        if store.canReviewDiff {
            Button { showing = true } label: { Label("Review changes", systemImage: "plus.forwardslash.minus") }
                .accessibilityIdentifier("reviewChanges")
                .sheet(isPresented: $showing) { DiffReviewView().environmentObject(store) }
                .onChange(of: store.selectedID) { _, _ in showing = false }
        }
    }
}
