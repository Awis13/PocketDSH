import XCTest
import Foundation
import HarnessCore
@testable import harness

final class QueueRestartTests: XCTestCase {
    /// Drives the real `NativeHost.start()` restore path. Re-adding the old
    /// startup loop that cancelled pending commands would fail this test.
    func testHostStartupPreservesPendingWorkForExplicitResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EventStore(path: root.appendingPathComponent("engine.sqlite").path)
        let journal = try PresentationJournal(path: root.appendingPathComponent("ui.sqlite").path)
        _ = try await store.enqueue(session: "s", id: "p1", prompt: "preserve me", mode: .queue)
        let info = NativeSessionInfo(id: "s", title: "New task", workspace: root.path, model: "fixture", running: false, updatedAt: 0)
        try journal.register(session: "s", metadata: JSONEncoder().encode(info))
        let provider = try CompatibleProvider(baseURL: URL(string: "http://127.0.0.1:1/v1")!, model: "fixture")
        let host = try NativeHost(port: 0, token: String(repeating: "a", count: 32), workspace: root.path,
                                  model: "fixture", provider: provider, store: store, journal: journal)
        try await host.start()
        await host.stop()

        // Restart must neither discard pending work nor run it without resume.
        let pending = try await store.pending(session: "s")
        XCTAssertEqual(pending.map(\.id), ["p1"])
        let executed = try await store.load(session: "s").filter { $0.kind == "message" }
        XCTAssertTrue(executed.isEmpty)
    }
}
