import Foundation

/// Public addresses only. Credentials remain in SecureConnection's Keychain items.
enum SavedConnections {
    static let key = "harness.connections.v1"

    static func canonical(_ input: String) -> String? {
        guard var url = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/",
              ["https", "wss"].contains(url.scheme ?? "") ||
                (["http", "ws"].contains(url.scheme ?? "") && ["localhost", "127.0.0.1", "::1"].contains(host)) else { return nil }
        url.query = nil; url.fragment = nil; url.path = ""
        return url.url?.absoluteString
    }

    static func endpoints(in data: Data) -> [String] {
        let values = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return values.reduce(into: []) { result, value in
            if let endpoint = canonical(value), !result.contains(endpoint) { result.append(endpoint) }
        }
    }

    static func endpoint(native: Bool, current: String, in data: Data) -> String? {
        let candidates = endpoints(in: data).filter { $0.hasPrefix("ws") == native }
        if let current = canonical(current), candidates.contains(current) { return current }
        return candidates.first
    }

    static func remember(_ input: String, defaults: UserDefaults = .standard) {
        guard let endpoint = canonical(input) else { return }
        var values = endpoints(in: defaults.data(forKey: key) ?? Data())
        guard !values.contains(endpoint) else { return }
        values.append(endpoint)
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
    }
}
