import Foundation
import CryptoKit
import CoreFoundation

/// Not Codable: the body contains private conversation data and must never be
/// included in a diagnostic export. Count and completion use these same bytes.
public struct PreparedModelRequest: Sendable {
    public let id: String
    public let model: String
    public let messages: [Message]
    public let body: Data
    public let outputReserve: Int
    public let fingerprint: String
    let route: String
    let envelope: String
    let messageDigests: [String]
    let messageBytes: [Int]

    init(id: String, model: String, messages: [Message], body: Data, outputReserve: Int,
         route: String, envelope: Data, wireMessages: [Data]) {
        self.id = id; self.model = model; self.messages = messages; self.body = body
        self.outputReserve = outputReserve; self.route = route
        self.fingerprint = Self.digest(body)
        self.envelope = Self.digest(Data(route.utf8) + envelope)
        self.messageDigests = wireMessages.map(Self.digest)
        self.messageBytes = wireMessages.map(\.count)
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Metadata only. All counts are optional; missing or invalid is not zero.
/// OpenAI-compatible cached/reasoning details are subsets, not additive buckets.
public struct ProviderUsage: Codable, Sendable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let cachedTokens: Int?
    public let reasoningTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil,
                cachedTokens: Int? = nil, reasoningTokens: Int? = nil) {
        let prompt = TokenInteger.valid(promptTokens), completion = TokenInteger.valid(completionTokens)
        self.promptTokens = prompt; self.completionTokens = completion
        // Contradictory totals/details are unknown. Do not repair them into facts.
        let total = TokenInteger.valid(totalTokens)
        self.totalTokens = total.flatMap { value in
            if let prompt, value < prompt { return nil }
            if let completion, value < completion { return nil }
            if let prompt, let completion, value != prompt + completion { return nil }
            return value
        }
        self.cachedTokens = TokenInteger.valid(cachedTokens).flatMap { value in
            guard let prompt, value <= prompt else { return nil }; return value
        }
        self.reasoningTokens = TokenInteger.valid(reasoningTokens).flatMap { value in
            guard let completion, value <= completion else { return nil }; return value
        }
    }
    static func parse(_ object: [String: Any]) -> ProviderUsage {
        ProviderUsage(promptTokens: TokenInteger.parse(object["prompt_tokens"]),
            completionTokens: TokenInteger.parse(object["completion_tokens"]),
            totalTokens: TokenInteger.parse(object["total_tokens"]),
            cachedTokens: TokenInteger.parse((object["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]),
            reasoningTokens: TokenInteger.parse((object["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"]))
    }
}

/// JSON numbers must be finite, integral, nonnegative and exactly representable.
/// NSNumber also bridges Bool; accepting it would turn true into one token.
enum TokenInteger {
    static let maximum = 9_007_199_254_740_991
    static func valid(_ value: Int?) -> Int? {
        guard let value, (0...maximum).contains(value) else { return nil }; return value
    }
    static func parse(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d.isFinite, d >= 0, d <= Double(maximum), d.rounded(.towardZero) == d else { return nil }
        return Int(d)
    }
}
