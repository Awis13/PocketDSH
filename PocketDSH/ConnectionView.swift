import SwiftUI

struct ConnectionView: View {
    @Environment(\.harnessTheme) private var theme
    @EnvironmentObject var store: PocketStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 48, weight: .light)).padding(.top, 24)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your Mac at home.\nHarness on the go.").font(.system(size: 34, weight: .bold))
                        Text("Enable Tailscale on this device and paste the sign-in URL shown by DSH on your Mac.").foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SIGN-IN URL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        SecureField("https://your-mac.ts.net:3080/?token=…", text: $address)
                            .keyboardType(.URL).textContentType(.none).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(16).harnessSurface(radius: 14).accessibilityIdentifier("serverAddress")
                        Text("Address: \(store.endpoint)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange) }
                    Button {
                        busy = true
                        Task { await store.connect(input: address.isEmpty ? store.endpoint : address); busy = false }
                    } label: {
                        HStack { Spacer(); if busy || store.connecting { ProgressView().tint(.white) }; Text(busy ? "Connecting…" : "Connect").fontWeight(.semibold); Spacer() }.padding(16)
                    }.buttonStyle(.plain).background(Color.primary, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(theme.canvas).disabled(busy)
                    Label("Sign-in credentials are stored in this device’s Keychain. Model API keys stay on your Mac.", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
                    Text("You may need a new link after restarting DSH. To connect from your phone, replace 127.0.0.1 with your Mac’s HTTPS Tailscale address, keeping the port and token.").font(.footnote).foregroundStyle(.secondary)
                }.padding(26)
            }.background { ThemeBackdrop() }.foregroundStyle(theme.ink).navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .onChange(of: store.connected) { _, connected in if connected { address = ""; dismiss() } }
        }
    }
}
