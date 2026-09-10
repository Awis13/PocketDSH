import XCTest
@testable import HarnessCore

final class SSEDecoderTests: XCTestCase {
    func testCRLF() throws {
        var d = SSEDecoder()
        var events: [String] = []
        for b in "data: hello\r\n\r\n".utf8 { events += try d.feed(b) }
        events += try d.finish()
        XCTAssertEqual(events, ["hello"])
    }

    func testUnicodeSplit() throws {
        var d = SSEDecoder()
        var events: [String] = []
        let s = "data: \u{1F600}\n\n"
        for b in s.utf8 { events += try d.feed(b) }
        events += try d.finish()
        XCTAssertEqual(events, ["\u{1F600}"])
    }

    func testMultipleEvents() throws {
        var d = SSEDecoder()
        var events: [String] = []
        let s = "data: a\n\ndata: b\n\n"
        for b in s.utf8 { events += try d.feed(b) }
        events += try d.finish()
        XCTAssertEqual(events, ["a", "b"])
    }

    func testMultiline() throws {
        var d = SSEDecoder()
        var events: [String] = []
        let s = "data: line1\ndata: line2\n\n"
        for b in s.utf8 { events += try d.feed(b) }
        events += try d.finish()
        XCTAssertEqual(events, ["line1\nline2"])
    }

    func testEOFDiscardsPending() throws {
        var d = SSEDecoder()
        var events: [String] = []
        let s = "data: pending"
        for b in s.utf8 { events += try d.feed(b) }
        events += try d.finish()
        XCTAssertEqual(events, [])
    }

    func testOversizedPayload() throws {
        var d = SSEDecoder()
        let big = String(repeating: "a", count: 1048577)
        let s = "data: \(big)\n\n"
        var threw = false
        do {
            for b in s.utf8 { _ = try d.feed(b) }
        } catch {
            threw = true
        }
        XCTAssertTrue(threw)
    }
}
