import Foundation

public enum ProviderProfile: String, Codable, Sendable { case compatible, llamaCPP = "llama-cpp" }
public enum CapacitySource: String, Codable, Sendable { case configured, provider }
public enum CountSupport: String, Codable, Sendable { case unknown, supported, unsupported, unavailable }
public enum TokenCountKind: String, Codable, Sendable { case exact, estimated, unknown }
public enum TokenCountSource: String, Codable, Sendable { case server, usageAnchor, serializedBytes, none }

public struct ContextCapacity: Codable, Sendable, Equatable {
    public let tokens: Int
    public let source: CapacitySource
    public init(tokens: Int, source: CapacitySource) throws {
        guard TokenInteger.valid(tokens) != nil, tokens > 0 else { throw HarnessError.invalid("Invalid context capacity") }
        self.tokens = tokens; self.source = source
    }
}

public struct ProviderCapabilities: Codable, Sendable, Equatable {
    public let capacity: ContextCapacity?
    public let inputCounting: CountSupport
    public init(capacity: ContextCapacity? = nil, inputCounting: CountSupport = .unknown) {
        self.capacity = capacity; self.inputCounting = inputCounting
    }
}

public struct TokenCount: Codable, Sendable, Equatable {
    public let tokens: Int?
    public let kind: TokenCountKind
    public let source: TokenCountSource
    public init(tokens: Int? = nil, kind: TokenCountKind = .unknown, source: TokenCountSource = .none) {
        let valid = TokenInteger.valid(tokens)
        self.tokens = kind == .unknown ? nil : valid
        self.kind = valid == nil ? .unknown : kind
        self.source = self.tokens == nil ? .none : source
    }
}

public struct ContextBudget: Codable, Sendable, Equatable {
    public let requestID: String
    public let input: TokenCount
    public let outputReserve: Int
    public let capabilities: ProviderCapabilities
    /// Sanitized machine code; no provider body, URL or transport error text.
    public let countIssue: String?

    public init(request: PreparedModelRequest, input: TokenCount, capabilities: ProviderCapabilities,
                countIssue: String? = nil) {
        self.requestID = request.id; self.input = input; self.outputReserve = request.outputReserve
        self.capabilities = capabilities; self.countIssue = countIssue
    }
    public var remainingTokens: Int? {
        guard let capacity = capabilities.capacity?.tokens, let tokens = input.tokens else { return nil }
        return capacity - tokens - outputReserve
    }
    public var fits: Bool? { remainingTokens.map { $0 >= 0 } }
    /// A rough estimate must not turn an otherwise valid request into a refusal.
    public var shouldReject: Bool { input.kind == .exact && fits == false }
    public var fractionUsed: Double? {
        guard let capacity = capabilities.capacity?.tokens, capacity > 0, let tokens = input.tokens else { return nil }
        return Double(tokens + outputReserve) / Double(capacity)
    }
}

/// In-memory calibration, scoped to an engine. A prefix match is mandatory;
/// edits, compaction, tools, route/model/template changes invalidate the anchor.
/// Even an unchanged request remains an estimate: the server may have changed.
public struct UsageAnchor: Sendable {
    let envelope: String
    let messageDigests: [String]
    let promptTokens: Int
    public init?(request: PreparedModelRequest, usage: ProviderUsage?) {
        guard let tokens = usage?.promptTokens, TokenInteger.valid(tokens) != nil else { return nil }
        self.envelope = request.envelope; self.messageDigests = request.messageDigests; self.promptTokens = tokens
    }
    func estimate(_ request: PreparedModelRequest) -> TokenCount? {
        guard request.envelope == envelope, request.messageDigests.starts(with: messageDigests) else { return nil }
        let bytes = request.messageBytes.dropFirst(messageDigests.count).reduce(0, +)
        return TokenCount(tokens: promptTokens + Self.heuristic(bytes), kind: .estimated, source: .usageAnchor)
    }
    // This is deliberately labelled a heuristic, never an upper bound/tokenizer.
    static func heuristic(_ bytes: Int) -> Int { bytes / 4 + (bytes % 4 == 0 ? 0 : 1) }
}

public extension PreparedModelRequest {
    func estimatedInput(anchor: UsageAnchor? = nil) -> TokenCount {
        anchor?.estimate(self) ?? TokenCount(tokens: UsageAnchor.heuristic(body.count), kind: .estimated, source: .serializedBytes)
    }
}

public struct ProviderOptions: Sendable {
    public let profile: ProviderProfile
    public let contextCapacity: ContextCapacity?
    public let outputTokens: Int
    public let includeUsage: Bool

    public init(profile: ProviderProfile = .compatible, contextTokens: Int? = nil,
                outputTokens: Int = 4096, includeUsage: Bool? = nil) throws {
        guard TokenInteger.valid(outputTokens) != nil, outputTokens > 0 else { throw HarnessError.invalid("Invalid output token reserve") }
        let capacity = try contextTokens.map { try ContextCapacity(tokens: $0, source: .configured) }
        guard capacity == nil || outputTokens < capacity!.tokens else {
            throw HarnessError.invalid("Output token reserve must be smaller than the context limit")
        }
        self.profile = profile; self.contextCapacity = capacity; self.outputTokens = outputTokens
        self.includeUsage = includeUsage ?? (profile == .llamaCPP)
    }
    public static func environment(_ environment: [String: String]) throws -> ProviderOptions {
        guard let profile = ProviderProfile(rawValue: environment["HARNESS_PROVIDER_PROFILE"] ?? "compatible") else {
            throw HarnessError.invalid("HARNESS_PROVIDER_PROFILE must be compatible or llama-cpp")
        }
        func integer(_ key: String) throws -> Int? {
            guard let value = environment[key] else { return nil }
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value), number > 0 else {
                throw HarnessError.invalid("\(key) must be a positive integer")
            }
            return number
        }
        let usage: Bool?
        switch environment["HARNESS_INCLUDE_USAGE"] {
        case nil: usage = nil
        case "0": usage = false
        case "1": usage = true
        default: throw HarnessError.invalid("HARNESS_INCLUDE_USAGE must be 0 or 1")
        }
        return try ProviderOptions(profile: profile, contextTokens: integer("HARNESS_CONTEXT_TOKENS"),
            outputTokens: integer("HARNESS_OUTPUT_TOKENS") ?? 4096, includeUsage: usage)
    }
}
