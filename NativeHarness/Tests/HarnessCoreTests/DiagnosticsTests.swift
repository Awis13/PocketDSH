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
}