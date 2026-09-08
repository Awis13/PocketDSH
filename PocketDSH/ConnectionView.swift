import SwiftUI

struct ConnectionView: View {
    @Environment(\.harnessTheme) private var theme
    @EnvironmentObject var store: PocketStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var busy = false
    @State private var nativeEngine = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 48, weight: .light)).padding(.top, 24)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your Mac at home.\nHarness on the go.").font(.system(size: 34, weight: .bold))
                        Text(nativeEngine ? "Connect the existing chat to your Swift Native Harness host." : "Enable Tailscale on this device and paste the sign-in URL shown by DSH on your Mac.").foregroundStyle(.secondary)
                    }
                    Picker("Engine", selection: $nativeEngine) {
                        Text("DeepSeek Harness").tag(false)
                        Text("Native Harness").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("connectionEngine")
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
                            let input = address.isEmpty ? store.endpoint : address
                            let isNative = input.hasPrefix("ws://") || input.hasPrefix("wss://")
                            if isNative != nativeEngine { store.error = "Paste the connection URL for the selected engine." }
                            else { await store.connect(input: input) }
                            busy = false
                        }
                    } label: {
                        HStack { Spacer(); if busy || store.connecting { ProgressView().tint(.white) }; Text(busy ? "Connecting…" : "Connect").fontWeight(.semibold); Spacer() }.padding(16)
                    }.buttonStyle(.plain).background(Color.primary, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(theme.canvas).disabled(busy)
                    Label("Sign-in credentials are stored in this device’s Keychain. Model API keys stay on your Mac.", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
                    Text(nativeEngine ? "Preview: chat, shell, reasoning, tools, one-use permissions and stop. Images, voice, model switching and full access are not yet available. Saved sessions survive host restart; remote access requires a secure tunnel." : "You may need a new link after restarting DSH. To connect from your phone, replace 127.0.0.1 with your Mac’s HTTPS Tailscale address, keeping the port and token.").font(.footnote).foregroundStyle(.secondary)
                }.padding(26)
            }.background { ThemeBackdrop() }.foregroundStyle(theme.ink).navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .onAppear { nativeEngine = store.usesNativeHarness }
                .onChange(of: nativeEngine) { _, _ in address = "" }
                .onChange(of: store.connected) { _, connected in if connected { address = ""; dismiss() } }
        }
    }
}
