import Foundation

public struct ApprovalRequest: Codable, Sendable, Equatable {
    public let id: String
    public let call: ToolCall
    public let workspace: String
}

/// One-use decisions bound to an exact tool call. Closed controllers fail closed.
public actor ApprovalController {
    private var open = true
    private var waiting: [String: (ApprovalRequest, CheckedContinuation<Bool, any Error>)] = [:]
    public init() {}
    public func pending() -> [ApprovalRequest] { waiting.values.map(\.0).sorted { $0.id < $1.id } }
    public func answer(id: String, allow: Bool) -> Bool {
        guard let entry = waiting.removeValue(forKey: id) else { return false }
        entry.1.resume(returning: allow)
        return true
    }
    public func close() {
        open = false
        let entries = waiting.values; waiting.removeAll()
        for entry in entries { entry.1.resume(returning: false) }
    }
    private func cancel(_ id: String) {
        waiting.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }
    public func request(_ request: ApprovalRequest,
                        notify: @escaping @Sendable (ApprovalRequest) -> Void) async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                guard open else { continuation.resume(returning: false); return }
                guard waiting[request.id] == nil else {
                    continuation.resume(throwing: HarnessError.invalid("Duplicate approval ID")); return
                }
                waiting[request.id] = (request, continuation)
                notify(request)
            }
        } onCancel: { Task { await self.cancel(request.id) } }
    }
}

public struct ToolExecutionContext: Sendable {
    public var update: @Sendable (LiveUpdate) -> Void
    public var record: @Sendable (SessionEvent) async throws -> Void
    public init(update: @escaping @Sendable (LiveUpdate) -> Void = { _ in },
                record: @escaping @Sendable (SessionEvent) async throws -> Void = { _ in }) {
        self.update = update; self.record = record
    }
}
