import XCTest
@testable import HarnessCore

@MainActor final class ContextBudgetTests: XCTestCase {
    func provider(options: ProviderOptions? = nil, thinking: Bool = false) throws -> CompatibleProvider {
        try CompatibleProvider(baseURL: URL(string: "http://127.0.0.1:1/proxy/v1")!, model: "fixture/model",
            disableThinking: thinking, options: options)
    }
    func testPreparedRequestIncludesSystemToolsAndTemplateAndFreezesBytes() async throws {
        let provider = try provider(options: ProviderOptions(outputTokens: 123, includeUsage: true), thinking: true)
        var history = [Message(role: "user", content: "hello")]
        let tools = [ToolDefinition(name: "b", description: "desc", properties: ["z": "z", "a": "a"], required: ["a"]),
                     ToolDefinition(name: "a", description: "next", properties: [:], required: [])]
        let prepared = try await provider.prepare(messages: history, tools: tools)
        history[0].content = "changed"
        let again = try await provider.prepare(messages: prepared.messages, tools: tools)
        XCTAssertEqual(prepared.body, again.body)
        let object = try JSONSerialization.jsonObject(with: prepared.body) as! [String: Any]
        let messages = object["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.map { $0["role"] as! String }, ["system", "user"])
        XCTAssertEqual(messages.last?["content"] as? String, "hello")
        XCTAssertEqual((object["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertEqual((object["stream_options"] as? [String: Bool])?["include_usage"], true)
        XCTAssertEqual(object["max_tokens"] as? Int, 123)
        let names = (object["tools"] as! [[String: Any]]).map { ($0["function"] as! [String: Any])["name"] as! String }
        XCTAssertEqual(names, ["b", "a"])
        XCTAssertEqual(try provider.completionRequest(prepared).httpBody, prepared.body)
        XCTAssertThrowsError(try self.provider().completionRequest(prepared))
        XCTAssertEqual(prepared.outputReserve, 123)
    }
    func testToolCallAndResultOrderIsPreserved() async throws {
        let calls = [ToolCall(id: "second", name: "b", arguments: "{}"), ToolCall(id: "first", name: "a", arguments: "{}")]
        let history = [Message(role: "assistant", content: "", calls: calls), Message(role: "tool", content: "b", toolCallID: "second"), Message(role: "tool", content: "a", toolCallID: "first")]
        let prepared = try await provider().prepare(messages: history, tools: [])
        let object = try JSONSerialization.jsonObject(with: prepared.body) as! [String: Any]
        let messages = object["messages"] as! [[String: Any]]
        XCTAssertEqual((messages[1]["tool_calls"] as! [[String: Any]]).map { $0["id"] as! String }, ["second", "first"])
        XCTAssertEqual(messages.suffix(2).map { $0["tool_call_id"] as! String }, ["second", "first"])
    }
    func testCountBodyUsesClippedTerminalPayloadWithoutChangingHistory() async throws {
        let terminal = try TerminalObservation(id: "fixture", initialWorkspace: "/tmp")
        terminal.append(Data((String(repeating: "\u{1b}[31mROW\u{1b}[0m\r\n", count: 1200) + "END_MARKER").utf8))
        let read = try terminal.read(after: 0, maxBytes: 65536)
        let original = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        let history = [Message(role: "assistant", content: "", calls: [.init(id: "t", name: "terminal_read", arguments: "{}")]),
                       Message(role: "tool", content: original, toolCallID: "t")]
        let request = try await provider().prepare(messages: history, tools: [])
        let object = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
        let messages = object["messages"] as! [[String: Any]]
        let excerpt = messages.last!["content"] as! String
        let payload = try JSONSerialization.jsonObject(with: Data(excerpt.utf8)) as! [String: Any]
        XCTAssertNil(payload["bytes"])
        XCTAssertTrue((payload["text"] as! String).hasSuffix("END_MARKER"))
        XCTAssertLessThanOrEqual((payload["text"] as! String).utf8.count, 4096)
        XCTAssertEqual(request.messages, history)
        XCTAssertEqual(try terminal.read(after: 0, maxBytes: 65536).bytes, read.bytes)
    }
    func testUsageAnchorOnlyCalibratesUnchangedEnvelopeAndPrefix() async throws {
        let provider = try provider()
        let first = try await provider.prepare(messages: [.init(role: "user", content: "hello")], tools: [])
        let anchor = UsageAnchor(request: first, usage: ProviderUsage(promptTokens: 80, cachedTokens: 60))!
        XCTAssertEqual(first.estimatedInput(anchor: anchor), TokenCount(tokens: 80, kind: .estimated, source: .usageAnchor))
        let extended = try await provider.prepare(messages: first.messages + [.init(role: "assistant", content: "ok")], tools: [])
        XCTAssertEqual(extended.estimatedInput(anchor: anchor).source, .usageAnchor)
        XCTAssertGreaterThan(extended.estimatedInput(anchor: anchor).tokens!, 80)
        let edited = try await provider.prepare(messages: [.init(role: "user", content: "summary replaces history")], tools: [])
        XCTAssertEqual(edited.estimatedInput(anchor: anchor).source, .serializedBytes)
        let newTools = try await provider.prepare(messages: first.messages, tools: [.init(name: "new", description: "schema", properties: [:], required: [])])
        XCTAssertEqual(newTools.estimatedInput(anchor: anchor).source, .serializedBytes)
        let otherModel = try CompatibleProvider(baseURL: URL(string: "http://127.0.0.1:1/proxy/v1")!, model: "different")
        let changedModel = try await otherModel.prepare(messages: first.messages, tools: [])
        XCTAssertEqual(changedModel.estimatedInput(anchor: anchor).source, .serializedBytes)
        let changedTemplate = try await self.provider(thinking: true).prepare(messages: first.messages, tools: [])
        XCTAssertEqual(changedTemplate.estimatedInput(anchor: anchor).source, .serializedBytes)
    }
    func testGenericProfileNeverProbesAndUnknownCapacityHasNoPercentage() async throws {
        var provider = try provider()
        provider.measurementTransport = { _ in XCTFail("Generic mode must not probe"); throw URLError(.badURL) }
        let prepared = try await provider.prepare(messages: [.init(role: "user", content: "hello")], tools: [])
        let budget = try await provider.measure(prepared)
        XCTAssertEqual(budget.input.kind, .estimated)
        XCTAssertNil(budget.remainingTokens); XCTAssertNil(budget.fractionUsed); XCTAssertNil(budget.fits)
        XCTAssertFalse(budget.shouldReject)
        let object = try JSONSerialization.jsonObject(with: prepared.body) as! [String: Any]
        XCTAssertNil(object["stream_options"])
    }
    func testKnownLimitIncludesReserveButEstimatesNeverBlock() async throws {
        let provider = try provider(options: ProviderOptions(contextTokens: 100, outputTokens: 20))
        let request = try await provider.prepare(messages: [], tools: [])
        let capabilities = ProviderCapabilities(capacity: try ContextCapacity(tokens: 100, source: .configured))
        for (tokens, remaining) in [(79, 1), (80, 0), (81, -1)] {
            let exact = ContextBudget(request: request, input: .init(tokens: tokens, kind: .exact, source: .server), capabilities: capabilities)
            XCTAssertEqual(exact.remainingTokens, remaining)
            XCTAssertEqual(exact.shouldReject, remaining < 0)
            let estimate = ContextBudget(request: request, input: .init(tokens: tokens, kind: .estimated, source: .serializedBytes), capabilities: capabilities)
            XCTAssertFalse(estimate.shouldReject)
        }
    }
    func testLlamaCountsExactBodyAndReadsModelScopedSlotCapacity() async throws {
        var provider = try provider(options: ProviderOptions(profile: .llamaCPP, outputTokens: 20))
        let prepared = try await provider.prepare(messages: [.init(role: "user", content: "payload")], tools: [])
        provider.measurementTransport = { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/proxy/v1/chat/completions/input_tokens")
                XCTAssertEqual(request.httpBody, prepared.body)
                return MeasurementResponse(data: Data(#"{"object":"response.input_tokens","input_tokens":81}"#.utf8), status: 200)
            }
            XCTAssertEqual(request.url?.path, "/proxy/props")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(URLQueryItem(name: "model", value: "fixture/model")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "autoload", value: "false")))
            return MeasurementResponse(data: Data(#"{"default_generation_settings":{"n_ctx":100},"n_ctx_train":99999,"total_slots":8}"#.utf8), status: 200)
        }
        let budget = try await provider.measure(prepared)
        XCTAssertEqual(budget.input, .init(tokens: 81, kind: .exact, source: .server))
        XCTAssertEqual(budget.capabilities.capacity?.tokens, 100)
        XCTAssertEqual(budget.capabilities.capacity?.source, .provider)
        XCTAssertTrue(budget.shouldReject)
    }
    func testConfiguredCapacitySkipsPropsAndUnsupportedCountFallsBack() async throws {
        var provider = try provider(options: ProviderOptions(profile: .llamaCPP, contextTokens: 1000, outputTokens: 20))
        provider.measurementTransport = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return MeasurementResponse(data: Data("<html>not found</html>".utf8), status: 404)
        }
        let request = try await provider.prepare(messages: [], tools: [])
        let budget = try await provider.measure(request)
        XCTAssertEqual(budget.capabilities.capacity?.source, .configured)
        XCTAssertEqual(budget.capabilities.inputCounting, .unsupported)
        XCTAssertEqual(budget.input.kind, .estimated)
        XCTAssertEqual(budget.countIssue, "COUNT_UNSUPPORTED")
    }
    func testTimeoutAndInvalidResponsesAreUnknownNotFakeExactCounts() async throws {
        for value in ["-1", "1.5", "true", "null", #""7""#] {
            var provider = try provider(options: ProviderOptions(profile: .llamaCPP, contextTokens: 1000, outputTokens: 20))
            provider.measurementTransport = { _ in MeasurementResponse(data: Data("{\"object\":\"response.input_tokens\",\"input_tokens\":\(value)}".utf8), status: 200) }
            let request = try await provider.prepare(messages: [], tools: [])
            let budget = try await provider.measure(request)
            XCTAssertEqual(budget.input.kind, .estimated, value)
            XCTAssertEqual(budget.countIssue, "COUNT_INVALID_RESPONSE")
        }
        var provider = try provider(options: ProviderOptions(profile: .llamaCPP))
        provider.measurementTransport = { _ in throw URLError(.timedOut) }
        let request = try await provider.prepare(messages: [], tools: [])
        let budget = try await provider.measure(request)
        XCTAssertEqual(budget.countIssue, "COUNT_TIMEOUT")
        XCTAssertNil(budget.capabilities.capacity)
    }
    func testCancelledMeasurementNeverFallsBackToGeneration() async throws {
        var provider = try provider(options: ProviderOptions(profile: .llamaCPP))
        provider.measurementTransport = { _ in throw URLError(.cancelled) }
        let request = try await provider.prepare(messages: [], tools: [])
        do { _ = try await provider.measure(request); XCTFail("Must cancel") } catch is CancellationError { }
        let captured = provider
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await captured.prepare(messages: [], tools: [])
        }
        do { _ = try await task.value; XCTFail("Must cancel preparation") } catch is CancellationError { }
    }
    func testOptionsValidateBothCLIPathsThroughSharedEnvironmentParser() throws {
        let options = try ProviderOptions.environment(["HARNESS_PROVIDER_PROFILE": "llama-cpp", "HARNESS_CONTEXT_TOKENS": "10000", "HARNESS_OUTPUT_TOKENS": "512", "HARNESS_INCLUDE_USAGE": "0"])
        XCTAssertEqual(options.contextCapacity?.tokens, 10000)
        XCTAssertEqual(options.outputTokens, 512); XCTAssertFalse(options.includeUsage)
        for environment in [["HARNESS_PROVIDER_PROFILE":"unknown"], ["HARNESS_CONTEXT_TOKENS":"0"], ["HARNESS_CONTEXT_TOKENS":"1.5"], ["HARNESS_CONTEXT_TOKENS":"true"], ["HARNESS_OUTPUT_TOKENS":"-1"], ["HARNESS_CONTEXT_TOKENS":"4096"], ["HARNESS_INCLUDE_USAGE":"yes"]] {
            XCTAssertThrowsError(try ProviderOptions.environment(environment))
        }
    }
    func testValidCountDoesNotInventCapacityFromTrainingContextOrBadProps() async throws {
        var provider = try provider(options: ProviderOptions(profile: .llamaCPP))
        provider.measurementTransport = { request in
            MeasurementResponse(data: Data((request.httpMethod == "POST"
                ? #"{"object":"response.input_tokens","input_tokens":7}"#
                : #"{"n_ctx_train":99999,"default_generation_settings":{"n_ctx":true}}"#).utf8), status: 200)
        }
        let request = try await provider.prepare(messages: [], tools: [])
        let budget = try await provider.measure(request)
        XCTAssertEqual(budget.input.kind, .exact)
        XCTAssertNil(budget.capabilities.capacity)
        XCTAssertNil(budget.fits); XCTAssertFalse(budget.shouldReject)
    }
}
