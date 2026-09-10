import Foundation

public enum HarnessError: Error, CustomStringConvertible, Sendable {
    case invalid(String), busy, storage(String), provider(String), httpStatus(Int), limit, contextLimit
    public var description: String {
        switch self {
        case .invalid(let s), .storage(let s), .provider(let s): s
        case .busy: "Session already running"
        case .httpStatus(let code): "Provider HTTP \(code)"
        case .limit: "Step limit reached"
        case .contextLimit: "Model context limit exceeded. The conversation and terminal are preserved. Start a new session or reduce the attached output."
        }
    }
}

public struct ToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

public struct Message: Codable, Sendable, Equatable {
    public var role: String
    public var content: String
    public var calls: [ToolCall]
    public var toolCallID: String?
    public init(role: String, content: String, calls: [ToolCall] = [], toolCallID: String? = nil) {
        self.role = role; self.content = content; self.calls = calls; self.toolCallID = toolCallID
    }
}

public struct ModelReply: Sendable {
    public var message: Message
    public var finishReason: String
    public var usage: ProviderUsage?
    public init(message: Message, finishReason: String = "stop", usage: ProviderUsage? = nil) {
        self.message = message; self.finishReason = finishReason; self.usage = usage
    }
}

public struct SessionEvent: Codable, Sendable {
    public var contextCompaction: ContextCompactionMetadata?
    public var commandID: String?
    public var trace: TraceContext?
    public var kind: String
    public var message: Message?
    public var call: ToolCall?
    public var detail: String?
    public init(_ kind: String, message: Message? = nil, call: ToolCall? = nil, detail: String? = nil) {
        self.kind = kind; self.message = message; self.call = call; self.detail = detail
    }
}

/// The result of one tool call: the model-visible output plus any inline diff
/// the host wants to render beside it. Only `edit_file` currently populates
/// `diffs`; every other tool leaves it empty.
public struct ToolOutput: Sendable, Equatable {
    public var output: String
    public var diffs: [ToolDiffHunk]
    public init(output: String, diffs: [ToolDiffHunk] = []) {
        self.output = output; self.diffs = diffs
    }
}

public enum LiveUpdate: Sendable {
    case text(String), reasoning(String), tool(String)
    case toolCall(ToolCall), toolResult(id: String, output: String, failed: Bool, diffs: [ToolDiffHunk])
    case providerHeaders, providerData
    case approval(ApprovalRequest), shell(ShellOutput)
    case diagnostic(DiagnosticEvent)
    case compaction(CompactionReceipt)
}

public protocol ModelProvider: Sendable {
    func prepare(messages: [Message], tools: [ToolDefinition], requestID: String) async throws -> PreparedModelRequest
    func measure(_ request: PreparedModelRequest, anchor: UsageAnchor?) async throws -> ContextBudget
    func complete(_ request: PreparedModelRequest,
                  onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> ModelReply
}

public struct ToolDefinition: Sendable {
    public var name: String
    public var description: String
    public var properties: [String: String]
    public var required: [String]
}

public protocol ToolExecutor: Sendable {
    var definitions: [ToolDefinition] { get }
    var workspaceIdentity: String { get }
    func execute(_ call: ToolCall) async throws -> ToolOutput
    func execute(_ call: ToolCall, context: ToolExecutionContext) async throws -> ToolOutput
}

public extension ToolExecutor {
    func execute(_ call: ToolCall, context: ToolExecutionContext) async throws -> ToolOutput {
        try await execute(call)
    }
}
