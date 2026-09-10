import XCTest
@testable import HarnessCore

final class StreamingEdgeTests: XCTestCase {
    func testContextOverflowIsClassifiedWithoutExposingProviderBody() {
        let body = Data(#"{"error":{"message":"request (80847 tokens) exceeds the available context size (80128 tokens), try increasing it","type":"exceed_context_size_error"}}"#.utf8)
        XCTAssertTrue(CompatibleProvider.isContextOverflow(body))
        XCTAssertEqual(DiagnosticTrace.errorCode(HarnessError.contextLimit), "CONTEXT_LIMIT")
        XCTAssertFalse(CompatibleProvider.isContextOverflow(Data(#"{"error":{"message":"Invalid model"}}"#.utf8)))
        XCTAssertFalse(CompatibleProvider.isContextOverflow(Data("<html>bad gateway</html>".utf8)))
    }
    func testStandaloneCRDispatchesAndKeepsFollowingLine() throws {
        var parser = SSEDecoder()
        var events: [String] = []
        for byte in "data: one\r\rdata: two\r\r".utf8 { events += try parser.feed(byte) }
        XCTAssertEqual(events, ["one", "two"])
    }
    func testFieldWithNoColonHasEmptyValue() throws {
        var parser = SSEDecoder()
        var events: [String] = []
        for byte in "data\n\n".utf8 { events += try parser.feed(byte) }
        XCTAssertEqual(events, [""])
    }
    func testMalformedUTF8AtEOF() throws {
        var parser = SSEDecoder()
        _ = try parser.feed(0xF0)
        XCTAssertThrowsError(try parser.finish())
    }
    func testEOFDiscardDoesNotLeakIntoNextStream() throws {
        var parser = SSEDecoder()
        for byte in "data: discarded\n".utf8 { _ = try parser.feed(byte) }
        _ = try parser.finish()
        var events: [String] = []
        for byte in "data: kept\n\n".utf8 { events += try parser.feed(byte) }
        XCTAssertEqual(events, ["kept"])
    }
    func testInterleavedToolArgumentFragmentsAreAssembledByIndex() throws {
        var assembly = ReplyAssembly()
        let frames = [
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"read_file","arguments":"{\"path\":"}},{"index":1,"id":"b","function":{"name":"list_files","arguments":"{\"path\":"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\".\"}"}},{"index":0,"function":{"arguments":"\"note\"}"}}]},"finish_reason":"tool_calls"}]}"#]
        for frame in frames { _ = try assembly.consume(frame, onUpdate: { _ in }) }
        let reply = try assembly.reply()
        XCTAssertEqual(reply.message.calls.map(\.id), ["a", "b"])
        XCTAssertEqual(reply.message.calls[0].arguments, #"{"path":"note"}"#)
        XCTAssertEqual(reply.message.calls[1].arguments, #"{"path":"."}"#)
    }
}
