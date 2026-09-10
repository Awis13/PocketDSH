import XCTest
import Foundation
@testable import HarnessCore

final class DiagnosticsTests: XCTestCase {
    func testBoundedRetentionAndDroppedCount() {
        let trace = DiagnosticTrace()
        for _ in 0..<300 {
            trace.record(.accepted)
        }
        let snap = trace.snapshot()
        XCTAssertEqual(snap.events.count, 256)
        XCTAssertEqual(snap.droppedEvents, 44)
        XCTAssertEqual(snap.events.first?.sequence, 45)
        XCTAssertEqual(snap.events.last?.sequence, 300)
    }

    func testMonotonicSequenceAndElapsed() {
        let trace = DiagnosticTrace()
        trace.record(.accepted)
        trace.record(.restoring)
        trace.record(.ready)
        let snap = trace.snapshot()
        let seqs = snap.events.map(\.sequence)
        XCTAssertEqual(seqs, [1, 2, 3])
        let elapsed = snap.events.map(\.elapsedMS)
        for i in 1..<elapsed.count {
            XCTAssertGreaterThanOrEqual(elapsed[i], elapsed[i - 1])
        }
    }

    func testRequestIdentifiersChangePerBeginRequest() {
        let trace = DiagnosticTrace()
        trace.beginRequest()
        let first = trace.identifiers()
        XCTAssertNotNil(first.requestID)
        trace.beginRequest()
        let second = trace.identifiers()
        XCTAssertNotNil(second.requestID)
        XCTAssertNotEqual(first.requestID, second.requestID)
        XCTAssertNotEqual(first.stepID, second.stepID)
    }

    func testToolIDPresentAfterBeginTool() {
        let trace = DiagnosticTrace()
        trace.beginRequest()
        XCTAssertNil(trace.identifiers().toolID)
        trace.beginTool()
        XCTAssertNotNil(trace.identifiers().toolID)
    }

    func testFirstReasoningAndFirstTextDistinguishedAndRepeatsSuppressed() {
        let trace = DiagnosticTrace()
        let diag = RequestDiagnostics(trace)
        diag.observe(.reasoning("thinking"))
        diag.observe(.reasoning("more thinking"))
        diag.observe(.text("hello"))
        diag.observe(.text("world"))
        let snap = trace.snapshot()
        let stages = snap.events.map(\.stage)
        XCTAssertEqual(stages, [.firstReasoning, .firstText])
    }

    func testRequestSummarySurvivesRingOverflowAndMilestonesAreFirstOnly() {
        let trace = DiagnosticTrace()
        trace.beginRequest(); trace.record(.measuring); trace.record(.measured); trace.record(.requesting)
        trace.record(.firstData); trace.record(.firstText)
        let first = trace.snapshot().requests[0].firstTextMS
        for _ in 0..<300 { trace.record(.queued) }
        trace.record(.firstText); trace.record(.modelCompleted)
        let result = trace.snapshot()
        XCTAssertFalse(result.events.contains { $0.stage == .requesting })
        XCTAssertEqual(result.requests.count, 1)
        XCTAssertEqual(result.requests[0].firstTextMS, first)
        XCTAssertEqual(result.requests[0].stage, "modelCompleted")
        XCTAssertEqual(result.events.last?.request?.requestID, result.requests[0].requestID)
        XCTAssertNotNil(result.requests[0].preparationMS)
        XCTAssertNotNil(result.requests[0].measurementMS)
        let elapsed = result.requests[0].elapsedMS
        trace.record(.toolStarted); trace.record(.failed, code: "STORAGE_FAILURE")
        XCTAssertEqual(trace.snapshot().requests[0].elapsedMS, elapsed)
        XCTAssertEqual(trace.snapshot().requests[0].stage, "modelCompleted", "Tool/persistence failure is not a failed model request")
    }
    func testIndependentRequestRetentionIsBounded() {
        let trace = DiagnosticTrace()
        for _ in 0..<140 { trace.beginRequest(); trace.record(.requesting); trace.record(.failed, code: "HTTP_400") }
        XCTAssertEqual(trace.snapshot().requests.count, 128)
        XCTAssertEqual(trace.snapshot().droppedRequests, 12)
        XCTAssertEqual(trace.snapshot().requests.last?.code, "HTTP_400")
    }
    func testUnknownStageSurvivesDiagnosticRoundtrip() throws {
        let source = Data(#"{"sequence":1,"elapsedMS":0,"sincePreviousMS":0,"context":{"sessionID":"s","turnID":"t"},"stage":"futureOperation"}"#.utf8)
        let event = try JSONDecoder().decode(DiagnosticEvent.self, from: source)
        XCTAssertEqual(event.stage.rawValue, "futureOperation")
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)).stage, event.stage)
    }
}