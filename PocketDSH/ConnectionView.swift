import SwiftUI

struct ConnectionView: View {
    @Environment(\.harnessTheme) private var theme
    @EnvironmentObject var store: PocketStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var busy = false
    @State private var nativeEngine = false
    @AppStorage(SavedConnections.key) private var savedConnections = Data()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 48, weight: .light)).padding(.top, 24)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your Mac at home.\nHarness on the go.").font(.system(size: 34, weight: .bold))
                        Text(nativeEngine ? "Connect the existing chat to your Swift Native Harness host." : "Enable Tailscale on this device and paste the sign-in URL shown by DSH on your Mac.").foregroundStyle(.secondary)
                    }
                    if !SavedConnections.endpoints(in: savedConnections).isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SAVED CONNECTIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(SavedConnections.endpoints(in: savedConnections), id: \.self) { endpoint in
                                Button {
                                    connectSaved(endpoint)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: endpoint.hasPrefix("ws") ? "terminal" : "network")
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(endpoint.hasPrefix("ws") ? "Native Harness" : "DeepSeek Harness").fontWeight(.medium)
                                            Text(endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer()
                                        if store.connected && endpoint == store.endpoint { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent) }
                                    }.padding(14).contentShape(Rectangle())
                                }.buttonStyle(.plain).harnessSurface(radius: 14).disabled(busy || store.connecting)
                                    .accessibilityIdentifier("saved-connection-" + endpoint)
                            }
                        }
                    }
                    Picker("Engine", selection: Binding(get: { nativeEngine }, set: selectEngine)) {
                        Text("DeepSeek Harness").tag(false)
                        Text("Native Harness").tag(true)
                    }.pickerStyle(.segmented).disabled(busy || store.connecting).accessibilityIdentifier("connectionEngine")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SIGN-IN URL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        SecureField(nativeEngine ? "ws://127.0.0.1:8768?token=…" : "https://your-mac.ts.net:3080/?token=…", text: $address)
                            .keyboardType(.URL).textContentType(.none).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(16).harnessSurface(radius: 14).accessibilityIdentifier("serverAddress")
                        Text("Address: \(store.endpoint)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange) }
                    Button {
                        busy = true
                        Task {
                            let input = address.isEmpty
                                ? SavedConnections.endpoint(native: nativeEngine, current: store.endpoint, in: savedConnections) ?? ""
                                : address
                            let isNative = input.hasPrefix("ws://") || input.hasPrefix("wss://")
                            if input.isEmpty || isNative != nativeEngine { store.error = "Paste the connection URL for the selected engine." }
                            else { await store.connect(input: input) }
                            busy = false
                        }
                    } label: {
                        HStack { Spacer(); if busy || store.connecting { ProgressView().tint(.white) }; Text(busy ? "Connecting…" : "Connect").fontWeight(.semibold); Spacer() }.padding(16)
                    }.buttonStyle(.plain).background(Color.primary, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(theme.canvas).disabled(busy)
                    Label("Sign-in credentials are stored in this device’s Keychain. Model API keys stay on your Mac.", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
                    Text("Pocket DSH \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))").font(.caption).foregroundStyle(.secondary)
                    Text(nativeEngine ? "Preview: chat, shell, reasoning, tools, one-use permissions and stop. Images, voice, model switching and full access are not yet available. Saved sessions survive host restart; remote access requires a secure tunnel." : "You may need a new link after restarting DSH. To connect from your phone, replace 127.0.0.1 with your Mac’s HTTPS Tailscale address, keeping the port and token.").font(.footnote).foregroundStyle(.secondary)
                }.padding(26)
            }.background { ThemeBackdrop() }.foregroundStyle(theme.ink).navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .onAppear { nativeEngine = store.usesNativeHarness }
                .onChange(of: nativeEngine) { _, _ in address = "" }
                .onChange(of: store.connected) { _, connected in if connected { address = ""; dismiss() } }
        }
    }

    private func selectEngine(_ native: Bool) {
        nativeEngine = native
        address = ""
        guard let endpoint = SavedConnections.endpoint(native: native, current: store.endpoint, in: savedConnections) else {
            store.error = "Add a \(native ? "Native Harness" : "DeepSeek Harness") sign-in URL to connect."
            return
        }
        connectSaved(endpoint)
    }

    private func connectSaved(_ endpoint: String) {
        nativeEngine = endpoint.hasPrefix("ws")
        address = ""
        guard !store.connected || SavedConnections.canonical(store.endpoint) != endpoint else { return }
        busy = true
        Task { await store.connect(input: endpoint); busy = false }
    }
}
