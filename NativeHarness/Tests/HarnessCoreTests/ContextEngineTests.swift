import XCTest
@testable import HarnessCore

private actor BudgetEngineProvider: TestModelProvider {
    let exact: Bool
    let holdMeasurement: Bool
    private(set) var measuring = false
    private(set) var completedRequests: [PreparedModelRequest] = []
    private(set) var sawAnchor = false
    init(exact: Bool, holdMeasurement: Bool = false) { self.exact = exact; self.holdMeasurement = holdMeasurement }
    func measure(_ request: PreparedModelRequest, anchor: UsageAnchor?) async throws -> ContextBudget {
        measuring = true
        sawAnchor = anchor != nil
        if holdMeasurement { try await Task.sleep(for: .seconds(30)) }
        return ContextBudget(request: request, input: .init(tokens: 100, kind: exact ? .exact : .estimated, source: exact ? .server : .serializedBytes),
            capabilities: ProviderCapabilities(capacity: try ContextCapacity(tokens: 1000, source: .configured)))
    }
    func complete(_ request: PreparedModelRequest, onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> ModelReply {
        completedRequests.append(request)
        return ModelReply(message: .init(role: "assistant", content: "ok"), usage: .init(promptTokens: 100, completionTokens: 1, totalTokens: 101))
    }
}

@MainActor final class ContextEngineTests: XCTestCase {
    private func setup(_ provider: BudgetEngineProvider) throws -> (SessionEngine, EventStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try EventStore(path: root.appendingPathComponent("events.sqlite").path)
        return (SessionEngine(id: "fixture", store: store, provider: provider, tools: try WorkspaceTools(root: root)), store)
    }
    func testExactOverflowStopsBeforeGenerationAndPreservesPrompt() async throws {
        let provider = BudgetEngineProvider(exact: true)
        let (engine, store) = try setup(provider)
        do { _ = try await engine.run(prompt: "retain me"); XCTFail("Reserve must be counted") } catch HarnessError.contextLimit { }
        let generated = await provider.completedRequests
        XCTAssertTrue(generated.isEmpty)
        let budget = await engine.contextBudget()
        XCTAssertEqual(budget?.outputReserve, 4096)
        XCTAssertEqual(budget?.shouldReject, true)
        let history = try await store.load(session: "fixture")
        XCTAssertEqual(history.compactMap(\.message).map(\.content), ["retain me"])
        XCTAssertTrue(SessionEngine.recovery(history).isEmpty)
    }
    func testOverBudgetEstimateDoesNotBlockAndUsageFeedsNextRequest() async throws {
        let provider = BudgetEngineProvider(exact: false)
        let (engine, _) = try setup(provider)
        _ = try await engine.run(prompt: "first")
        let usage = await engine.providerUsage()
        XCTAssertEqual(usage?.totalTokens, 101)
        _ = try await engine.run(prompt: "next")
        let requests = await provider.completedRequests
        let sawAnchor = await provider.sawAnchor
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(sawAnchor)
        let budget = await engine.contextBudget()
        let trace = await engine.diagnostics()
        XCTAssertEqual(budget?.requestID, requests.last?.id)
        XCTAssertEqual(trace?.requests.last?.requestID, requests.last?.id)
    }
    func testStopDuringMeasurementCancelsWithoutGenerationAndRetainsQueuedWork() async throws {
        let provider = BudgetEngineProvider(exact: false, holdMeasurement: true)
        let (engine, _) = try setup(provider)
        let task = Task { try await engine.run(prompt: "first") }
        for _ in 0..<200 {
            if await provider.measuring { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let measuring = await provider.measuring
        XCTAssertTrue(measuring)
        _ = try await engine.enqueue(prompt: "later", commandID: "pending")
        await engine.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch is CancellationError { }
        let requests = await provider.completedRequests
        XCTAssertTrue(requests.isEmpty)
        let pending = try await engine.pending()
        XCTAssertEqual(pending.map(\.id), ["pending"])
        let trace = await engine.diagnostics()
        XCTAssertEqual(trace?.events.last?.stage, .cancelled)
    }
}
