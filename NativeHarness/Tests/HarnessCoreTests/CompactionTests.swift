import XCTest
import CSQLite
@testable import HarnessCore

actor CompactionProvider: ModelProvider {
    private var prepared = try! CompatibleProvider(baseURL: URL(string: "http://127.0.0.1:1/v1")!, model: "fixture",
        options: ProviderOptions(outputTokens: 64))
    var capacity: Int?
    var kind: TokenCountKind = .exact
    var reply = ModelReply(message: .init(role: "assistant", content: "Earlier work was inspected. Preserve pending work and verify unknown tool outcomes."))
    var candidateOverflow = false
    var holdSummary = false
    var holdValidation = false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    private(set) var generated: [PreparedModelRequest] = []
    private var candidateMeasurements = 0
    init(capacity: Int? = 5000) { self.capacity = capacity }
    func configure(reply: ModelReply? = nil, holdSummary: Bool = false, holdValidation: Bool = false, kind: TokenCountKind = .exact) {
        if let reply { self.reply = reply }
        self.holdSummary = holdSummary; self.holdValidation = holdValidation; self.kind = kind
    }
    func overflowCandidate() { candidateOverflow = true }
    func release() { holdSummary = false; holdValidation = false; gate?.resume(); gate = nil; waiting = false }
    func changeModel() throws {
        prepared = try CompatibleProvider(baseURL: URL(string: "http://127.0.0.1:1/v1")!, model: "changed",
            options: ProviderOptions(outputTokens: 64))
    }
    func prepare(messages: [Message], tools: [ToolDefinition], requestID: String) async throws -> PreparedModelRequest {
        try await prepared.prepare(messages: messages, tools: tools, requestID: requestID)
    }
    func measure(_ request: PreparedModelRequest, anchor: UsageAnchor?) async throws -> ContextBudget {
        if request.messages.first?.content.hasPrefix("[Earlier conversation summary") == true {
            candidateMeasurements += 1
            if holdValidation, candidateMeasurements == 2 { waiting = true; await withCheckedContinuation { gate = $0 } }
        }
        return ContextBudget(request: request, input: .init(tokens: candidateOverflow && request.messages.first?.content.hasPrefix("[Earlier conversation summary") == true ? capacity! : request.body.count, kind: kind,
            source: kind == .exact ? .server : .serializedBytes),
            capabilities: .init(capacity: try capacity.map { try ContextCapacity(tokens: $0, source: .configured) }))
    }
    func complete(_ request: PreparedModelRequest, onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> ModelReply {
        generated.append(request)
        if request.messages.first?.content.hasPrefix("Summarize historical") == true {
            if holdSummary { waiting = true; await withCheckedContinuation { gate = $0 } }
            onUpdate(.text("PRIVATE_SUMMARY")); onUpdate(.reasoning("PRIVATE_REASONING"))
            return reply
        }
        onUpdate(.text("normal answer"))
        return .init(message: .init(role: "assistant", content: "normal answer"))
    }
}

final class CompactionOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var completed = 0
    func record(_ update: LiveUpdate) {
        lock.lock(); defer { lock.unlock() }
        switch update {
        case .text(let text), .reasoning(let text): texts.append(text)
        case .diagnostic(let event): if event.stage == .completed { completed += 1 }
        default: break
        }
    }
    func snapshot() -> ([String], Int) { lock.lock(); defer { lock.unlock() }; return (texts, completed) }
}

actor CompactionTools: ToolExecutor {
    nonisolated let workspaceIdentity: String
    nonisolated let definitions = [ToolDefinition(name: "fixture_tool", description: "Test side effects", properties: [:], required: [])]
    private(set) var count = 0
    init(_ path: String) { workspaceIdentity = path }
    func execute(_ call: ToolCall) async throws -> ToolOutput { count += 1; return ToolOutput(output: "side effect") }
}

@MainActor class CompactionTestCase: XCTestCase {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func seed(_ store: EventStore, session: String = "s", old: Int = 1200, recent: Int = 20) async throws {
        for i in 0..<6 {
            let text = String(repeating: "x", count: i < 4 ? old : recent)
            try await store.append([.init("turn.started"),
                .init("message", message: .init(role: "user", content: "request \(i) \(text)")),
                .init("message", message: .init(role: "assistant", content: "answer \(i) \(text)")),
                .init("turn.ended")], session: session)
        }
    }
    func fixture(_ provider: CompactionProvider, policy: CompactionPolicy = try! CompactionPolicy()) async throws -> (SessionEngine, EventStore, CompactionTools) {
        let root = try directory(), store = try EventStore(path: root.appendingPathComponent("db").path)
        try await seed(store)
        let tools = CompactionTools(root.path)
        return (SessionEngine(id: "s", store: store, provider: provider, tools: tools, compactionPolicy: policy), store, tools)
    }
    func wait(_ provider: CompactionProvider) async throws {
        for _ in 0..<400 {
            if await provider.waiting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Provider did not reach the bounded test barrier")
        throw HarnessError.provider("Test barrier timeout")
    }
}

final class CompactionTests: CompactionTestCase {
    func testChunkedSummaryFitsAndPreservesRecentTurnsAndOriginalLog() async throws {
        let provider = CompactionProvider()
        let (engine, store, tools) = try await fixture(provider)
        let before = try await store.loadContext(session: "s")
        let result = try await engine.compact(operationID: "compact")
        XCTAssertEqual(result.state, .completed, result.code ?? "")
        XCTAssertGreaterThan(result.summaryRequests, 1)
        XCTAssertLessThanOrEqual(result.summaryRequests, 4)
        XCTAssertEqual(result.before?.input.kind, .exact)
        XCTAssertLessThan(result.after!.input.tokens!, result.before!.input.tokens!)
        let after = try await store.loadContext(session: "s")
        XCTAssertEqual(Array(after.messages.dropFirst()), Array(before.messages.suffix(4)))
        XCTAssertEqual(after.version, before.version + 1)
        let source = try await store.load(session: "s")
        XCTAssertEqual(source.compactMap(\.message), before.messages)
        XCTAssertFalse(source.compactMap(\.message).contains { $0.content.contains("PRIVATE_SUMMARY") })
        let generated = await provider.generated
        for request in generated {
            XCTAssertLessThanOrEqual(request.body.count + request.outputReserve, 5000)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            XCTAssertEqual((body["tools"] as? [Any])?.count, 0)
        }
        let count = await tools.count
        XCTAssertEqual(count, 0)
        let retry = try await engine.compact(operationID: "compact")
        XCTAssertEqual(retry, result)
        let afterRetry = await provider.generated.count
        XCTAssertEqual(afterRetry, generated.count)
        let diagnostics = await engine.diagnostics()!
        XCTAssertTrue(diagnostics.requests.filter { $0.dispatched == true }.allSatisfy { $0.purpose == "compaction" })
        XCTAssertTrue(diagnostics.requests.filter { $0.purpose == "compactionValidation" }.allSatisfy { $0.dispatched != true })
    }

    func testSelectionProtectsOpenTurnAndTwoCompletedTurnsWithMultipleTools() async throws {
        let provider = CompactionProvider()
        let (_, store, _) = try await fixture(provider)
        let calls = [ToolCall(id: "a", name: "one", arguments: "{}"), ToolCall(id: "b", name: "two", arguments: "{}")]
        try await store.append([.init("turn.started"), .init("message", message: .init(role: "user", content: "active")),
            .init("message", message: .init(role: "assistant", content: "", calls: calls)),
            .init("message", message: .init(role: "tool", content: "one", toolCallID: "a")),
            .init("message", message: .init(role: "tool", content: "two", toolCallID: "b"))], session: "s")
        let snapshot = try await store.loadContext(session: "s")
        let selection = try ContextCompactor.select(snapshot, recentTurns: 2)
        XCTAssertEqual(selection.retained, Array(snapshot.messages.suffix(8)))
        XCTAssertEqual(selection.groups.flatMap { $0 }.count, 8)
        var malformed = snapshot.tail
        malformed.removeLast()
        let invalid = ContextSnapshot(sessionID: "s", version: snapshot.version, projection: nil, tail: malformed)
        XCTAssertThrowsError(try ContextCompactor.select(invalid, recentTurns: 2))
    }

    func testUnknownCapacityAndOversizedProtectedTailNeverGenerate() async throws {
        for provider in [CompactionProvider(capacity: nil), CompactionProvider(capacity: 300)] {
            let (engine, store, _) = try await fixture(provider)
            let result = try await engine.compact(operationID: "blocked")
            XCTAssertEqual(result.state, .failed)
            XCTAssertTrue([CompactionError.unknownCapacity.rawValue, CompactionError.protectedTail.rawValue].contains(result.code!))
            let generated = await provider.generated
            XCTAssertTrue(generated.isEmpty)
            let context = try await store.loadContext(session: "s")
            XCTAssertNil(context.projection)
        }
    }

    func testInvalidAndNonShrinkingSummariesNeverCommitOrDispatchTools() async throws {
        let replies: [ModelReply] = [
            .init(message: .init(role: "assistant", content: "  \n")),
            .init(message: .init(role: "assistant", content: "cut off"), finishReason: "length"),
            .init(message: .init(role: "assistant", content: "", calls: [.init(id: "bad", name: "fixture_tool", arguments: "{}")])),
            .init(message: .init(role: "tool", content: "unexpected")),
            .init(message: .init(role: "assistant", content: String(repeating: "x", count: 20000))) ]
        for reply in replies {
            let provider = CompactionProvider()
            await provider.configure(reply: reply)
            let (engine, store, tools) = try await fixture(provider)
            let before = try await store.loadContext(session: "s")
            let result = try await engine.compact(operationID: "invalid")
            XCTAssertEqual(result.state, .failed)
            XCTAssertTrue([CompactionError.invalidSummary.rawValue, CompactionError.notSmaller.rawValue].contains(result.code!))
            let after = try await store.loadContext(session: "s")
            XCTAssertEqual(before.messages, after.messages)
            XCTAssertEqual(before.version, after.version)
            let count = await tools.count
            XCTAssertEqual(count, 0)
        }
    }

    func testRequestLimitLeavesNoPartialProjection() async throws {
        let provider = CompactionProvider()
        let (engine, store, _) = try await fixture(provider, policy: CompactionPolicy(maxRequests: 1))
        let result = try await engine.compact(operationID: "limited")
        XCTAssertEqual(result.code, CompactionError.requestLimit.rawValue)
        XCTAssertEqual(result.summaryRequests, 1)
        let after = try await store.loadContext(session: "s")
        XCTAssertNil(after.projection)
        XCTAssertEqual(after.version, 12)
    }

    func testIndivisibleToolGroupIsNotSplitOrSentOversized() async throws {
        let provider = CompactionProvider()
        let root = try directory(), store = try EventStore(path: root.appendingPathComponent("db").path)
        let calls = [ToolCall(id: "a", name: "one", arguments: "{}"), ToolCall(id: "b", name: "two", arguments: "{}")]
        try await store.append([.init("turn.started"), .init("message", message: .init(role: "assistant", content: "", calls: calls)),
            .init("message", message: .init(role: "tool", content: String(repeating: "z", count: 8000), toolCallID: "a")),
            .init("message", message: .init(role: "tool", content: "second", toolCallID: "b")), .init("turn.ended")], session: "s")
        try await seed(store, old: 10, recent: 10)
        let engine = SessionEngine(id: "s", store: store, provider: provider, tools: CompactionTools(root.path))
        let result = try await engine.compact(operationID: "group")
        XCTAssertEqual(result.code, CompactionError.indivisibleGroup.rawValue)
        let sent = await provider.generated
        XCTAssertTrue(sent.isEmpty)
    }

    func testAutomaticCompactionContinuesConversationWithSummaryInPlace() async throws {
        let provider = CompactionProvider()
        let (engine, store, tools) = try await fixture(provider)
        let output = CompactionOutput()
        let answer = try await engine.run(prompt: "continue", onUpdate: output.record)
        XCTAssertEqual(answer, "normal answer")
        XCTAssertEqual(output.snapshot().0, ["normal answer"])
        XCTAssertEqual(output.snapshot().1, 1)
        let generated = await provider.generated
        XCTAssertEqual(generated.last?.messages.first?.content.hasPrefix("[Earlier conversation summary"), true)
        XCTAssertEqual(generated.last?.messages.last?.content, "continue")
        let history = try await store.load(session: "s")
        XCTAssertEqual(history.filter { $0.kind == "context.compacted" }.count, 1)
        XCTAssertEqual(history.compactMap(\.message).count, 14)
        let count = await tools.count
        XCTAssertEqual(count, 0)
    }
    func testFinalPreparedBudgetMustFitBeforeCommit() async throws {
        let provider = CompactionProvider()
        await provider.overflowCandidate()
        let (engine, store, _) = try await fixture(provider)
        let result = try await engine.compact(operationID: "final-overflow")
        XCTAssertEqual(result.code, CompactionError.stillTooLarge.rawValue)
        let context = try await store.loadContext(session: "s")
        XCTAssertNil(context.projection)
        XCTAssertEqual(context.version, 12)
    }

    func testMeasurementLimitBoundsPlanningAndLeavesOriginalHistory() async throws {
        let provider = CompactionProvider()
        let (engine, store, _) = try await fixture(provider, policy: CompactionPolicy(maxMeasurements: 4))
        let result = try await engine.compact(operationID: "count-limit")
        XCTAssertEqual(result.code, CompactionError.measurementLimit.rawValue)
        let context = try await store.loadContext(session: "s")
        XCTAssertNil(context.projection)
        let requests = await provider.generated
        XCTAssertLessThanOrEqual(requests.count, 1)
    }

    func testAutomaticUnknownCapacityDoesNotGuessPressureAndEstimatedCountsStayEstimated() async throws {
        let unknown = CompactionProvider(capacity: nil)
        let (engine, store, _) = try await fixture(unknown)
        _ = try await engine.run(prompt: "continue without a known limit")
        let requests = await unknown.generated
        XCTAssertEqual(requests.count, 1)
        let original = try await store.loadContext(session: "s")
        XCTAssertNil(original.projection)
        let estimated = CompactionProvider()
        await estimated.configure(kind: .estimated)
        let (other, _, _) = try await fixture(estimated)
        let result = try await other.compact(operationID: "estimated")
        XCTAssertEqual(result.state, .completed, result.code ?? "")
        XCTAssertEqual(result.before?.input.kind, .estimated)
        XCTAssertEqual(result.after?.input.kind, .estimated)
    }

}
