import XCTest
import Foundation
@testable import HarnessCore

private final class PTYCapture: @unchecked Sendable {
    let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; data.append(bytes) }
    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
final class PTYTests: XCTestCase, @unchecked Sendable {
    private func waitFor(_ marker: String, _ capture: PTYCapture) async throws {
        for _ in 0..<250 {
            if capture.text().contains(marker) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("PTY did not emit \(marker): \(capture.text())")
        throw HarnessError.invalid("PTY test timeout")
    }
    func testControllingTerminalResizeAndPersistentState() async throws {
        let capture = PTYCapture()
        let session = try PTYSession(workspace: FileManager.default.temporaryDirectory, rows: 24, columns: 80, onOutput: capture.append)
        defer { session.close() }
        try session.write(Data("[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && stty -a < /dev/tty >/dev/null && printf '\\nTTY_OK\\n'; stty size\r".utf8))
        try await waitFor("\r\nTTY_OK\r\n", capture)
        try await waitFor("24 80\r\n", capture)
        try session.resize(rows: 41, columns: 113)
        try session.write(Data("stty size; export HARNESS_PTY_TEST=persistent; cd /; printf '\\nSTATE_READY\\n'\r".utf8))
        try await waitFor("41 113\r\n", capture)
        try await waitFor("\r\nSTATE_READY\r\n", capture)
        try session.write(Data("printf '\\n%s:%s\\n' \"$HARNESS_PTY_TEST\" \"$PWD\"; exit 7\r".utf8))
        let exit = await session.wait()
        XCTAssertEqual(exit.code, 7)
        XCTAssertFalse(exit.closedByHost)
        XCTAssertTrue(capture.text().contains("\r\npersistent:/\r\n"))
    }
    func testInterruptForegroundJobKeepsShellAlive() async throws {
        let capture = PTYCapture()
        let session = try PTYSession(workspace: FileManager.default.temporaryDirectory, onOutput: capture.append)
        defer { session.close() }
        try session.write(Data("printf '\\nSLEEPING\\n'; sleep 20\r".utf8))
        try await waitFor("\r\nSLEEPING\r\n", capture)
        try await Task.sleep(for: .milliseconds(100))
        try session.interrupt()
        try session.write(Data("printf '\\nSTILL_ALIVE\\n'\r".utf8))
        try await waitFor("\r\nSTILL_ALIVE\r\n", capture)
        session.close()
        let result = await session.wait()
        XCTAssertTrue(result.closedByHost)
        XCTAssertThrowsError(try session.write(Data("late".utf8)))
        XCTAssertThrowsError(try session.resize(rows: 50, columns: 80))
    }
    func testRawUnicodeBytesAndCloseDuringOutput() async throws {
        let capture = PTYCapture()
        let session = try PTYSession(workspace: FileManager.default.temporaryDirectory, onOutput: capture.append)
        defer { session.close() }
        let command = Data("printf '\\nПривет 🌍\\n'\r".utf8)
        for byte in command { try session.write(Data([byte])) }
        try await waitFor("\r\nПривет 🌍\r\n", capture)
        XCTAssertThrowsError(try session.write(Data(repeating: 65, count: 65537)))
        XCTAssertThrowsError(try session.resize(rows: 0, columns: 80))
        try session.write(Data("while true; do printf x; done\r".utf8))
        try await Task.sleep(for: .milliseconds(50))
        session.close(); session.close()
        let result = await session.wait()
        XCTAssertTrue(result.closedByHost)
    }
    func testExplicitInterruptWorksWithTerminalSignalsDisabled() async throws {
        let capture = PTYCapture()
        let session = try PTYSession(workspace: FileManager.default.temporaryDirectory, onOutput: capture.append)
        defer { session.close() }
        try session.write(Data("stty -isig; printf '\\nRAW_READY\\n'; sleep 20\r".utf8))
        try await waitFor("\r\nRAW_READY\r\n", capture)
        try await Task.sleep(for: .milliseconds(100))
        try session.interrupt()
        try await Task.sleep(for: .milliseconds(100))
        try session.write(Data("stty isig; printf '\\nRAW_INTERRUPTED_SHELL_ALIVE\\n'\r".utf8))
        try await waitFor("\r\nRAW_INTERRUPTED_SHELL_ALIVE\r\n", capture)
    }
}
