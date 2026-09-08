import Foundation
import CryptoKit

public struct TraceContext: Codable, Sendable, Equatable {
    public let sessionID: String
    public let turnID: String
    public var stepID: String?
    public var requestID: String?
    public var toolID: String?
}

public enum DiagnosticStage: String, Codable, Sendable {
    case accepted, restoring, ready, requesting, headers, firstData, firstReasoning, firstText
    case modelCompleted, toolStarted, toolCompleted, toolFailed, persisting
    case cancellationRequested, completed, cancelled, failed
    case queued, steered, turnCompleted
}

public struct DiagnosticEvent: Codable, Sendable {
    public let sequence: Int
    public let elapsedMS: Double
    public let sincePreviousMS: Double
    public let context: TraceContext
    public let stage: DiagnosticStage
    public let code: String?
}

public struct DiagnosticSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let events: [DiagnosticEvent]
    public let droppedEvents: Int
    public let elapsedMS: Double
    public let requests: [RequestTiming]
}

public struct RequestTiming: Codable, Sendable {
    public let requestID: String
    public var responseHeadersMS: Double?
    public var firstDataMS: Double?
    public var firstReasoningMS: Double?
    public var firstTextMS: Double?
    public var modelCompletedMS: Double?

    public static func summarize(_ events: [DiagnosticEvent]) -> [RequestTiming] {
        events.filter { $0.stage == .requesting }.compactMap { start in
            guard let id = start.context.requestID else { return nil }
            var result = RequestTiming(requestID: id)
            for event in events where event.context.requestID == id {
                let elapsed = max(0, event.elapsedMS - start.elapsedMS)
                switch event.stage {
                case .headers: result.responseHeadersMS = elapsed
                case .firstData: result.firstDataMS = elapsed
                case .firstReasoning: result.firstReasoningMS = elapsed
                case .firstText: result.firstTextMS = elapsed
                case .modelCompleted: result.modelCompletedMS = elapsed
                default: break
                }
            }
            return result
        }
    }
}

/// Bounded metadata only: no prompt, endpoint, key, file path, tool arguments,
/// model output, or raw Error.description. The lock protects synchronous stream
/// callbacks; callbacks must be short and must not perform network operations.
public final class DiagnosticTrace: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let started = ContinuousClock.now
    private var previous = ContinuousClock.now
    private var sequence = 0
    private var records: [DiagnosticEvent] = []
    private var dropped = 0
    private var context: TraceContext
    private let sink: @Sendable (DiagnosticEvent) -> Void
    public init(sessionID: String = UUID().uuidString, sink: @escaping @Sendable (DiagnosticEvent) -> Void = { _ in }) {
        // The caller may use a private project name as its session ID.
        let reference = SHA256.hash(data: Data(sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
        context = TraceContext(sessionID: reference, turnID: UUID().uuidString)
        self.sink = sink
    }

    public func beginRequest() {
        lock.lock(); defer { lock.unlock() }
        context.stepID = UUID().uuidString; context.requestID = UUID().uuidString; context.toolID = nil
    }
    func startTurn(_ value: TraceContext) {
        lock.lock(); defer { lock.unlock() }; context = value
    }
    public func beginTool() {
        lock.lock(); defer { lock.unlock() }
        context.toolID = UUID().uuidString
    }
    public func identifiers() -> TraceContext {
        lock.lock(); defer { lock.unlock() }; return context
    }
    public func record(_ stage: DiagnosticStage, code: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        let now = ContinuousClock.now
        sequence += 1
        let event = DiagnosticEvent(sequence: sequence, elapsedMS: Self.ms(started.duration(to: now)),
            sincePreviousMS: Self.ms(previous.duration(to: now)), context: context, stage: stage, code: code)
        previous = now
        if records.count == 256 { records.removeFirst(); dropped += 1 }
        records.append(event)
        sink(event)
    }
    public func snapshot() -> DiagnosticSnapshot {
        lock.lock(); defer { lock.unlock() }
        return DiagnosticSnapshot(schemaVersion: 1, events: records, droppedEvents: dropped,
                                  elapsedMS: Self.ms(started.duration(to: .now)), requests: RequestTiming.summarize(records))
    }
    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    static func errorCode(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "CANCELLED" }
        if let error = error as? HarnessError {
            switch error {
            case .busy: return "BUSY"
            case .invalid: return "INVALID_INPUT"
            case .storage: return "STORAGE_FAILURE"
            case .provider: return "PROVIDER_FAILURE"
            case .httpStatus(let code): return "HTTP_\(code)"
            case .limit: return "STEP_LIMIT"
            case .contextLimit: return "CONTEXT_LIMIT"
            }
        }
        if let url = error as? URLError { return "NETWORK_\(url.code.rawValue)" }
        if error is SSEError { return "INVALID_SSE" }
        return "OPERATION_FAILED"
    }
}

/// Records only the first observable milestones of a request, not each token.
final class RequestDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<DiagnosticStage> = []
    private let trace: DiagnosticTrace
    init(_ trace: DiagnosticTrace) { self.trace = trace }
    func observe(_ update: LiveUpdate) {
        let stage: DiagnosticStage
        switch update {
        case .text(let value): guard !value.isEmpty else { return }; stage = .firstText
        case .reasoning(let value): guard !value.isEmpty else { return }; stage = .firstReasoning
        case .providerHeaders: stage = .headers
        case .providerData: stage = .firstData
        default: return
        }
        lock.lock(); let first = seen.insert(stage).inserted; lock.unlock()
        if first { trace.record(stage) }
    }
}
