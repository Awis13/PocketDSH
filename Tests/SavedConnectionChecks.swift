import Foundation

@main struct SavedConnectionChecks {
    static func main() throws {
        let name = "PocketDSH.connections.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        SavedConnections.remember("https://mac.example:3080/?token=private-dsh#fragment", defaults: defaults)
        SavedConnections.remember("wss://mac.example:8769?token=private-native", defaults: defaults)
        SavedConnections.remember("https://mac.example:3080", defaults: defaults)
        SavedConnections.remember("http://remote.example?token=unsafe", defaults: defaults)
        SavedConnections.remember("wss://user:secret@remote.example", defaults: defaults)
        let data = defaults.data(forKey: SavedConnections.key)!
        precondition(SavedConnections.endpoints(in: data) == ["https://mac.example:3080", "wss://mac.example:8769"])
        let encoded = String(decoding: data, as: UTF8.self)
        for secret in ["private", "token", "secret", "unsafe", "fragment"] { precondition(!encoded.contains(secret)) }
        precondition(SavedConnections.endpoints(in: Data("invalid".utf8)).isEmpty)
        precondition(SavedConnections.endpoint(native: true, current: "https://mac.example:3080", in: data) == "wss://mac.example:8769")
        precondition(SavedConnections.endpoint(native: false, current: "wss://mac.example:8769", in: data) == "https://mac.example:3080")
        precondition(SavedConnections.endpoint(native: false, current: "https://mac.example:3080/", in: data) == "https://mac.example:3080")
        let dshOnly = try JSONEncoder().encode(["https://mac.example:3080"])
        precondition(SavedConnections.endpoint(native: true, current: "https://mac.example:3080", in: dshOnly) == nil)
        print("PASS: switching engines selects the matching saved server and never falls back to the other engine")
        print("PASS: both backends survive saved-connection reload; no credentials, duplicates or remote plaintext URLs")
    }
}
