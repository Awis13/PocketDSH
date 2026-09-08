import XCTest
@testable import HarnessCore

final class ProviderUsageTests: XCTestCase {
    func testUsageAfterFinishAndRepeatedFramesAreSnapshotsNotSums() throws {
        var parser = ReplyAssembly()
        _ = try parser.consume(#"{"choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}],"usage":null}"#, onUpdate: { _ in })
        let usage = #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"prompt_tokens_details":{"cached_tokens":80},"completion_tokens_details":{"reasoning_tokens":10}}}"#
        for _ in 0..<2 { _ = try parser.consume(usage, onUpdate: { _ in }) }
        XCTAssertTrue(try parser.consume("[DONE]", onUpdate: { _ in }))
        let reply = try parser.reply()
        XCTAssertEqual(reply.message.content, "answer")
        XCTAssertEqual(reply.usage, ProviderUsage(promptTokens: 100, completionTokens: 20, totalTokens: 120, cachedTokens: 80, reasoningTokens: 10))
    }
    func testInvalidCountsAreUnknownAndZeroIsValid() throws {
        let invalid = ["-1", "1.5", "true", "false", #""25""#, "null", "9007199254740992", "{}", "[]"]
        for value in invalid {
            let object = try JSONSerialization.jsonObject(with: Data("{\"prompt_tokens\":\(value),\"completion_tokens\":0}".utf8)) as! [String: Any]
            let usage = ProviderUsage.parse(object)
            XCTAssertNil(usage.promptTokens, value)
            XCTAssertEqual(usage.completionTokens, 0)
        }
        XCTAssertNil(ProviderUsage.parse([:]).promptTokens)
    }
    func testContradictoryTotalsAndDetailsAreNotInventedOrAdded() {
        let usage = ProviderUsage(promptTokens: 10, completionTokens: 5, totalTokens: 100, cachedTokens: 11, reasoningTokens: 6)
        XCTAssertNil(usage.totalTokens); XCTAssertNil(usage.cachedTokens); XCTAssertNil(usage.reasoningTokens)
        XCTAssertEqual(usage.promptTokens, 10)
        XCTAssertNil(ProviderUsage(cachedTokens: 5).cachedTokens)
        XCTAssertNil(ProviderUsage(promptTokens: 12).totalTokens)
    }
    func testAbsentUsageNullAndMissingFinishPreserveStreamValidation() throws {
        var parser = ReplyAssembly()
        _ = try parser.consume(#"{"choices":[],"usage":{"prompt_tokens":7}}"#, onUpdate: { _ in })
        XCTAssertThrowsError(try parser.reply())
        _ = try parser.consume(#"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":null}"#, onUpdate: { _ in })
        XCTAssertEqual(try parser.reply().usage?.promptTokens, 7)
        var without = ReplyAssembly()
        _ = try without.consume(#"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#, onUpdate: { _ in })
        XCTAssertNil(try without.reply().usage)
    }
}
