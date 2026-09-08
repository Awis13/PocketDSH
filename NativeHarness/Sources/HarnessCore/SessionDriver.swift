import Foundation

public struct DriverStatus: Codable, Sendable {
    public var compacting: Bool = false
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
    private var maintenance: Task<CompactionReceipt, Error>?
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
        if task == nil, maintenance == nil { task = Task { await self.drain() } }
    }
    public func stop() async {
        paused = true
        maintenance?.cancel()
        await engine.cancel()
    }
    public func status() async throws -> DriverStatus {
        let pending = try await engine.pending()
        let engineCompacting = await engine.isCompacting()
        return DriverStatus(compacting: maintenance != nil || engineCompacting, running: task != nil || maintenance != nil, paused: paused, pendingCount: pending.count, errorCode: errorCode)
    }
    public func waitUntilIdle() async {
        while task != nil || maintenance != nil {
            if let current = maintenance { _ = try? await current.value }
            if let current = task { await current.value }
        }
    }
    public func compact(operationID: String) async throws -> CompactionReceipt {
        if let receipt = try await engine.compactionReceipt(operationID: operationID) { return receipt }
        guard task == nil, maintenance == nil else { throw HarnessError.busy }
        let work = Task { try await self.engine.compact(operationID: operationID, onUpdate: self.update) }
        maintenance = work
        do {
            let receipt = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            maintenance = nil
            if receipt.state != .completed { errorCode = receipt.code; paused = true }
            if !paused {
                let pending = try await engine.pending()
                if !pending.isEmpty { resume() }
            }
            return receipt
        } catch {
            maintenance = nil; errorCode = DiagnosticTrace.errorCode(error); paused = true
            throw error
        }
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
