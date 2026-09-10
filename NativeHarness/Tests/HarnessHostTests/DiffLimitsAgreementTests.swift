import XCTest
import HarnessCore
@testable import harness

/// `ToolDiffLimits` bounds the core projection and `NativeDiffLimits` bounds the
/// wire frame the host publishes. The two live in different modules, so assert
/// the shared bounds field-by-field here to catch a silent drift between them.
final class DiffLimitsAgreementTests: XCTestCase {
    func testInlineDiffLimitsAgreeAcrossModules() {
        XCTAssertEqual(ToolDiffLimits.maximumHunks, NativeDiffLimits.maximumHunksPerFile)
        XCTAssertEqual(ToolDiffLimits.maximumLines, NativeDiffLimits.maximumLines)
        XCTAssertEqual(ToolDiffLimits.maximumFieldBytes, NativeDiffLimits.maximumFieldBytes)
        XCTAssertEqual(ToolDiffLimits.maximumTotalBytes, NativeDiffLimits.maximumTotalBytes)
    }
}
