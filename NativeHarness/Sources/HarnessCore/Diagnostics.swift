import Foundation
import CryptoKit

public struct TraceContext: Codable, Sendable, Equatable {
    public let sessionID: String
    public let turnID: String
    public var stepID: String?
    public var requestID: String?
    public var toolID: String?
}

/// Open string value so a newer stage survives trace decoding and replay.
public struct DiagnosticStage: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public static let accepted = Self(rawValue: "accepted")
    public static let restoring = Self(rawValue: "restoring")
    public static let ready = Self(rawValue: "ready")
    public static let preparing = Self(rawValue: "preparing")
    public static let measuring = Self(rawValue: "measuring")
    public static let superseded = Self(rawValue: "superseded")
    public static let measured = Self(rawValue: "measured")
    public static let requesting = Self(rawValue: "requesting")
    public static let headers = Self(rawValue: "headers")
    public static let firstData = Self(rawValue: "firstData")
    public static let firstReasoning = Self(rawValue: "firstReasoning")
    public static let firstText = Self(rawValue: "firstText")
    public static let modelCompleted = Self(rawValue: "modelCompleted")
    public static let toolStarted = Self(rawValue: "toolStarted")
    public static let toolCompleted = Self(rawValue: "toolCompleted")
    public static let toolFailed = Self(rawValue: "toolFailed")
    public static let persisting = Self(rawValue: "persisting")
    public static let cancellationRequested = Self(rawValue: "cancellationRequested")
    public static let completed = Self(rawValue: "completed")
    public static let cancelled = Self(rawValue: "cancelled")
    public static let failed = Self(rawValue: "failed")
    public static let queued = Self(rawValue: "queued")
    public static let steered = Self(rawValue: "steered")
    public static let turnCompleted = Self(rawValue: "turnCompleted")
}

public struct DiagnosticEvent: Codable, Sendable {
    public let sequence: Int
    public let elapsedMS: Double
    public let sincePreviousMS: Double
    public let context: TraceContext
    public let stage: DiagnosticStage
    public let code: String?
    public var request: RequestTiming? = nil
}

public struct DiagnosticSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let events: [DiagnosticEvent]
    public let droppedEvents: Int
    public let elapsedMS: Double
    public let requests: [RequestTiming]
    public var droppedRequests: Int? = nil
}

/// Request metadata is retained independently of the short event ring. Times
/// for response milestones start at dispatch, not at session or tool startup.
public struct RequestTiming: Codable, Sendable {
    public let requestID: String
    public var turnID: String?
    public var purpose: String?
    public var dispatched: Bool?
    public var stage: String?
    public var code: String?
    public var budget: ContextBudget?
    public var usage: ProviderUsage?
    public var elapsedMS: Double?
    public var preparationMS: Double?
    public var measurementMS: Double?
    public var responseHeadersMS: Double?
    public var firstDataMS: Double?
    public var firstReasoningMS: Double?
    public var firstTextMS: Double?
    public var modelCompletedMS: Double?

    public static func summarize(_ events: [DiagnosticEvent]) -> [RequestTiming] {
        var ledger = RequestLedger()
        for event in events { ledger.append(event) }
        return ledger.requests
    }
}

/// Used by both the live trace and CLI archive. No dependence on ring retention.
struct RequestLedger {
    private(set) var requests: [RequestTiming] = []
    private(set) var dropped = 0
    private var started: [String: Double] = [:]
    private var measuring: [String: Double] = [:]
    private var dispatched: [String: Double] = [:]
    mutating func append(_ event: DiagnosticEvent) {
        guard let id = event.context.requestID else { return }
        if !requests.contains(where: { $0.requestID == id }) {
            guard event.request != nil || event.stage == .preparing || event.stage == .requesting else { return }
            if requests.count == 128 {
                let removed = requests.removeFirst().requestID
                started[removed] = nil; measuring[removed] = nil; dispatched[removed] = nil; dropped += 1
            }
            requests.append(RequestTiming(requestID: id, turnID: event.context.turnID, purpose: "conversation"))
            started[id] = event.elapsedMS
        }
        guard let i = requests.firstIndex(where: { $0.requestID == id }) else { return }
        if let request = event.request { requests[i] = request; return }
        // Tool execution / final persistence must not inflate model latency or
        // change a completed request into a failed tool operation.
        if ["modelCompleted", "failed", "cancelled", "superseded"].contains(requests[i].stage ?? "") { return }
        let stages: Set<DiagnosticStage> = [.preparing, .measuring, .measured, .requesting, .headers,
            .firstData, .firstReasoning, .firstText, .modelCompleted, .failed, .cancelled, .superseded]
        guard stages.contains(event.stage) else { return }
        requests[i].stage = event.stage.rawValue; requests[i].code = event.code
        requests[i].elapsedMS = max(0, event.elapsedMS - (started[id] ?? event.elapsedMS))
        if event.stage == .measuring {
            measuring[id] = event.elapsedMS
            requests[i].preparationMS = requests[i].elapsedMS
        }
        if event.stage == .measured, let start = measuring[id] {
            requests[i].measurementMS = max(0, event.elapsedMS - start)
        }
        if event.stage == .requesting, dispatched[id] == nil { dispatched[id] = event.elapsedMS; requests[i].dispatched = true }
        guard let sent = dispatched[id] else { return }
        let ms = max(0, event.elapsedMS - sent)
        switch event.stage {
        case .headers: if requests[i].responseHeadersMS == nil { requests[i].responseHeadersMS = ms }
        case .firstData: if requests[i].firstDataMS == nil { requests[i].firstDataMS = ms }
        case .firstReasoning: if requests[i].firstReasoningMS == nil { requests[i].firstReasoningMS = ms }
        case .firstText: if requests[i].firstTextMS == nil { requests[i].firstTextMS = ms }
        case .modelCompleted: if requests[i].modelCompletedMS == nil { requests[i].modelCompletedMS = ms }
        default: break
        }
    }
    mutating func attach(budget: ContextBudget?, usage: ProviderUsage?, requestID: String?, purpose: String) {
        guard let i = requests.firstIndex(where: { $0.requestID == requestID }) else { return }
        requests[i].budget = budget; requests[i].usage = usage; requests[i].purpose = purpose
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
    private var ledger = RequestLedger()
    private var budget: ContextBudget?
    private var usage: ProviderUsage?
    private var purpose = "conversation"
    private var context: TraceContext
    private let sink: @Sendable (DiagnosticEvent) -> Void
    public init(sessionID: String = UUID().uuidString, sink: @escaping @Sendable (DiagnosticEvent) -> Void = { _ in }) {
        // The caller may use a private project name as its session ID.
        let reference = SHA256.hash(data: Data(sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
        context = TraceContext(sessionID: reference, turnID: UUID().uuidString)
        self.sink = sink
    }

    public func beginRequest(purpose: String = "conversation") {
        lock.lock(); defer { lock.unlock() }
        context.stepID = UUID().uuidString; context.requestID = UUID().uuidString; context.toolID = nil
        budget = nil; usage = nil; self.purpose = purpose
        record(.preparing)
    }
    public func setBudget(_ value: ContextBudget) {
        lock.lock(); defer { lock.unlock() }; budget = value; record(.measured)
    }
    public func setUsage(_ value: ProviderUsage?) {
        lock.lock(); defer { lock.unlock() }; usage = value
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
        var event = DiagnosticEvent(sequence: sequence, elapsedMS: Self.ms(started.duration(to: now)),
            sincePreviousMS: Self.ms(previous.duration(to: now)), context: context, stage: stage, code: code)
        ledger.append(event)
        ledger.attach(budget: budget, usage: usage, requestID: context.requestID, purpose: purpose)
        event.request = ledger.requests.last(where: { $0.requestID == context.requestID })
        previous = now
        if records.count == 256 { records.removeFirst(); dropped += 1 }
        records.append(event)
        sink(event)
    }
    public func snapshot() -> DiagnosticSnapshot {
        lock.lock(); defer { lock.unlock() }
        return DiagnosticSnapshot(schemaVersion: 1, events: records, droppedEvents: dropped,
                                  elapsedMS: Self.ms(started.duration(to: .now)), requests: ledger.requests, droppedRequests: ledger.dropped)
    }
    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    static func errorCode(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "CANCELLED" }
        if let error = error as? CompactionFailure { return error.receipt.code ?? "COMPACTION_FAILED" }
        if let error = error as? CompactionError { return error.rawValue }
        if error as? ContextProjectionError == .staleVersion { return "CONTEXT_STALE" }
        if error is ContextProjectionError { return "CONTEXT_INVALID" }
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
