import Foundation
@testable import HarnessCore

/// Scripted providers still exercise the same preparation boundary as production.
protocol TestModelProvider: ModelProvider {}
private enum TestPreparation {
    static let provider = try! CompatibleProvider(baseURL: URL(string: "http://127.0.0.1:1/v1")!, model: "fixture")
}
extension TestModelProvider {
    func prepare(messages: [Message], tools: [ToolDefinition], requestID: String) async throws -> PreparedModelRequest {
        try await TestPreparation.provider.prepare(messages: messages, tools: tools, requestID: requestID)
    }
    func measure(_ request: PreparedModelRequest, anchor: UsageAnchor?) async throws -> ContextBudget {
        try Task.checkCancellation()
        return ContextBudget(request: request, input: request.estimatedInput(anchor: anchor), capabilities: ProviderCapabilities())
    }
}
