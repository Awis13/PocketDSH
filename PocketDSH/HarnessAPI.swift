import Foundation
import Security

struct HarnessError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum SecureConnection {
    static func read(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.awis.PocketDSH", kSecAttrAccount as String: key, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ value: String, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.awis.PocketDSH", kSecAttrAccount as String: key]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw HarnessError(message: "Could not save sign-in credentials to Keychain") }; return
        }
        guard status == errSecSuccess else { throw HarnessError(message: "Could not update sign-in credentials in Keychain (\(status))") }
    }
}
@MainActor
final class HarnessAPI {
    let base: URL
    var cookie: String
    private let session: URLSession
    init(base: URL) {
        self.base = base; cookie = SecureConnection.read(base.absoluteString) ?? ""
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25; c.urlCache = nil
        session = URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }
    static func parse(_ input: String) throws -> (URL, String?) {
        guard var c = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.scheme == "https" || (c.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              c.path.isEmpty || c.path == "/" else { throw HarnessError(message: "Enter an HTTPS DSH URL, such as your Tailscale address. HTTP is only supported for localhost.") }
        let token = c.queryItems?.first { $0.name == "token" }?.value
        c.query = nil; c.fragment = nil; c.path = ""
        guard let base = c.url else { throw HarnessError(message: "Invalid URL") }
        return (base, token)
    }
    func login(token: String) async throws {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = "/"; c.queryItems = [.init(name: "token", value: token)]
        var request = URLRequest(url: c.url!); request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        let (_, response) = try await session.data(for: request)
        guard let r = response as? HTTPURLResponse, (200..<400).contains(r.statusCode) else { throw HarnessError(message: "This sign-in link has expired. Paste the current DSH launch URL.") }
        let headers = r.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: base)
        guard !cookies.isEmpty else { throw HarnessError(message: "DSH did not return a sign-in cookie") }
        cookie = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
        try SecureConnection.write(cookie, key: base.absoluteString)
    }
    func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        return r
    }
    func rpc(_ method: String, args: [String: JSON] = [:]) async throws -> JSON {
        var r = request("api/" + method); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(JSON.object(["type": .string("client-request"), "rpcId": .string(UUID().uuidString), "method": .string(method), "payload": .object(["args": .object(args)])]))
        let (data, response) = try await session.data(for: r)
        guard let response = response as? HTTPURLResponse else { throw HarnessError(message: "No response from DSH") }
        if response.statusCode == 401 { throw HarnessError(message: "Sign in again with a fresh DSH launch URL in Connection settings.") }
        guard response.statusCode == 200 else { throw HarnessError(message: "DSH: HTTP \(response.statusCode)") }
        let envelope: JSON
        do { envelope = try JSON.decodeWire(data) }
        catch {
            let kind = response.value(forHTTPHeaderField: "Content-Type") ?? "unknown content type"
            throw HarnessError(message: "Invalid DSH response for \(method): \(kind), \(data.count) bytes (HTTP \(response.statusCode)).")
        }
        let result = envelope["result"]
        guard result["ok"].bool else { throw HarnessError(message: result["error"]["message"].string) }
        return result["value"]
    }
    func transcribeVoice(_ audio: Data) async throws -> String {
        var r = request("pocket-voice/transcribe")
        r.httpMethod = "POST"; r.timeoutInterval = 180
        r.setValue("audio/mp4", forHTTPHeaderField: "Content-Type"); r.httpBody = audio
        let (data, response) = try await session.data(for: r)
        guard let response = response as? HTTPURLResponse else { throw HarnessError(message: "No response from DSH") }
        if response.statusCode == 404 { throw HarnessError(message: "Enable the Voice plugin on your DSH host.") }
        let result = try JSONDecoder().decode(JSON.self, from: data)
        guard response.statusCode == 200 else { throw HarnessError(message: result["error"].string.isEmpty ? "Transcription failed. Please retry." : result["error"].string) }
        let text = result["text"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw HarnessError(message: "No speech detected. Try recording again.") }
        return text
    }
    func socket() -> URLSessionWebSocketTask {
        var r = request("api/remote.mux")
        var c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
        c.scheme = base.scheme == "https" ? "wss" : "ws"; r.url = c.url
        let s = session.webSocketTask(with: r); s.maximumMessageSize = 32 * 1024 * 1024; s.resume(); return s
    }
}
