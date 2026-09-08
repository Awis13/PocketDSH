import Foundation

public struct DriverStatus: Codable, Sendable {
    public let running: Bool
    public let paused: Bool
    public let pendingCount: Int
    public let errorCode: String?
}

/// Host-facing wake policy. A generation counter handles commands arriving
/// while an empty drain is settling, without creating overlapping drivers.
public actor SessionDriver {
    private let engine: SessionEngine
    private let update: @Sendable (LiveUpdate) -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var paused = false
    private var errorCode: String?

    public init(engine: SessionEngine, onUpdate: @escaping @Sendable (LiveUpdate) -> Void = { _ in }) {
        self.engine = engine; self.update = onUpdate
    }
    public func submit(prompt: String, mode: DeliveryMode = .queue, commandID: String = UUID().uuidString) async throws -> CommandReceipt {
        let receipt = try await engine.enqueue(prompt: prompt, mode: mode, commandID: commandID)
        if receipt.state == .pending { resume() }
        return receipt
    }
    public func resume() {
        generation += 1; paused = false; errorCode = nil
        if task == nil { task = Task { await self.drain() } }
    }
    public func stop() async {
        paused = true
        await engine.cancel()
    }
    public func status() async throws -> DriverStatus {
        let pending = try await engine.pending()
        return DriverStatus(running: task != nil, paused: paused, pendingCount: pending.count, errorCode: errorCode)
    }
    public func waitUntilIdle() async {
        while let current = task { await current.value }
    }
    private func drain() async {
        while !paused {
            let startedGeneration = generation
            do {
                _ = try await engine.runPending(onUpdate: update)
                let observedGeneration = generation
                let remaining = try await engine.pending()
                if remaining.isEmpty, generation == observedGeneration { break }
            }
            catch {
                let code = DiagnosticTrace.errorCode(error)
                if code == "CANCELLED", !paused, generation != startedGeneration { continue }
                errorCode = code; paused = true; break
            }
        }
        task = nil
    }
}
