import Foundation

struct NativeCommand: Codable, Sendable {
    var op: String
    var session: String?
    var id: String?
    var text: String?
    var bytes: Data?
    var rows: Int?
    var columns: Int?
    var allow: Bool?
    var withTerminal: Bool?
    var completionKind: String?
}
struct NativeChat: Codable, Sendable, Identifiable {
    var id: String
    var role: String
    var text: String
}
struct NativeApproval: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var arguments: String
    var workspace: String
}
struct NativeSessionInfo: Codable, Sendable {
    var id: String
    var title: String
    var workspace: String
    var model: String
    var running: Bool
    var updatedAt: Double
}
struct NativeEvent: Codable, Sendable {
    var op: String
    var session: String?
    var id: String?
    var text: String?
    var bytes: Data?
    var stage: String?
    var model: String?
    var workspace: String?
    var ptyID: String?
    var chats: [NativeChat]?
    var approval: NativeApproval?
    var running: Bool?
    var gap: Bool?
    var sequence: Int?
    var exitCode: Int?
    var arguments: String?
    var failed: Bool?
    var sessions: [NativeSessionInfo]?
    var rows: Int?
    var columns: Int?
    var candidates: [String]?
    var limited: Bool?
    var request: NativeRequestInfo?
    var extraFields: [String: NativeJSON] = [:]
}

/// Preserve extension fields, including nested JSON, across host journal replay.
/// Decimal avoids turning large integer identifiers into rounded doubles.
indirect enum NativeJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Decimal), string(String), array([NativeJSON]), object([String: NativeJSON])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode([NativeJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: NativeJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
private struct NativeWireKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension NativeEvent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeWireKey.self)
        op = try c.decode(String.self, forKey: NativeWireKey("op"))
        session = try c.decodeIfPresent(String.self, forKey: NativeWireKey("session"))
        id = try c.decodeIfPresent(String.self, forKey: NativeWireKey("id"))
        text = try c.decodeIfPresent(String.self, forKey: NativeWireKey("text"))
        bytes = try c.decodeIfPresent(Data.self, forKey: NativeWireKey("bytes"))
        stage = try c.decodeIfPresent(String.self, forKey: NativeWireKey("stage"))
        model = try c.decodeIfPresent(String.self, forKey: NativeWireKey("model"))
        workspace = try c.decodeIfPresent(String.self, forKey: NativeWireKey("workspace"))
        ptyID = try c.decodeIfPresent(String.self, forKey: NativeWireKey("ptyID"))
        chats = try c.decodeIfPresent([NativeChat].self, forKey: NativeWireKey("chats"))
        approval = try c.decodeIfPresent(NativeApproval.self, forKey: NativeWireKey("approval"))
        running = try c.decodeIfPresent(Bool.self, forKey: NativeWireKey("running"))
        gap = try c.decodeIfPresent(Bool.self, forKey: NativeWireKey("gap"))
        sequence = try c.decodeIfPresent(Int.self, forKey: NativeWireKey("sequence"))
        exitCode = try c.decodeIfPresent(Int.self, forKey: NativeWireKey("exitCode"))
        arguments = try c.decodeIfPresent(String.self, forKey: NativeWireKey("arguments"))
        failed = try c.decodeIfPresent(Bool.self, forKey: NativeWireKey("failed"))
        sessions = try c.decodeIfPresent([NativeSessionInfo].self, forKey: NativeWireKey("sessions"))
        rows = try c.decodeIfPresent(Int.self, forKey: NativeWireKey("rows"))
        columns = try c.decodeIfPresent(Int.self, forKey: NativeWireKey("columns"))
        candidates = try c.decodeIfPresent([String].self, forKey: NativeWireKey("candidates"))
        limited = try c.decodeIfPresent(Bool.self, forKey: NativeWireKey("limited"))
        request = try? c.decodeIfPresent(NativeRequestInfo.self, forKey: NativeWireKey("request"))
        let known: Set<String> = ["op", "session", "id", "text", "bytes", "stage", "model", "workspace", "ptyID", "chats", "approval", "running", "gap", "sequence", "exitCode", "arguments", "failed", "sessions", "rows", "columns", "candidates", "limited", "request"]
        for key in c.allKeys where !known.contains(key.stringValue) || (key.stringValue == "request" && request == nil) {
            extraFields[key.stringValue] = try c.decode(NativeJSON.self, forKey: key)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: NativeWireKey.self)
        for (key, value) in extraFields { try c.encode(value, forKey: NativeWireKey(key)) }
        try c.encode(op, forKey: NativeWireKey("op"))
        try c.encodeIfPresent(session, forKey: NativeWireKey("session"))
        try c.encodeIfPresent(id, forKey: NativeWireKey("id"))
        try c.encodeIfPresent(text, forKey: NativeWireKey("text"))
        try c.encodeIfPresent(bytes, forKey: NativeWireKey("bytes"))
        try c.encodeIfPresent(stage, forKey: NativeWireKey("stage"))
        try c.encodeIfPresent(model, forKey: NativeWireKey("model"))
        try c.encodeIfPresent(workspace, forKey: NativeWireKey("workspace"))
        try c.encodeIfPresent(ptyID, forKey: NativeWireKey("ptyID"))
        try c.encodeIfPresent(chats, forKey: NativeWireKey("chats"))
        try c.encodeIfPresent(approval, forKey: NativeWireKey("approval"))
        try c.encodeIfPresent(running, forKey: NativeWireKey("running"))
        try c.encodeIfPresent(gap, forKey: NativeWireKey("gap"))
        try c.encodeIfPresent(sequence, forKey: NativeWireKey("sequence"))
        try c.encodeIfPresent(exitCode, forKey: NativeWireKey("exitCode"))
        try c.encodeIfPresent(arguments, forKey: NativeWireKey("arguments"))
        try c.encodeIfPresent(failed, forKey: NativeWireKey("failed"))
        try c.encodeIfPresent(sessions, forKey: NativeWireKey("sessions"))
        try c.encodeIfPresent(rows, forKey: NativeWireKey("rows"))
        try c.encodeIfPresent(columns, forKey: NativeWireKey("columns"))
        try c.encodeIfPresent(candidates, forKey: NativeWireKey("candidates"))
        try c.encodeIfPresent(limited, forKey: NativeWireKey("limited"))
        try c.encodeIfPresent(request, forKey: NativeWireKey("request"))
    }
}

/// An extensible metadata object with a deliberately narrow, validated UI API.
/// Unknown fields survive serialization but never enter the diagnostic export.
struct NativeRequestInfo: Codable, Sendable, Equatable, Identifiable {
    var fields: [String: NativeJSON]
    init(fields: [String: NativeJSON]) { self.fields = fields }
    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
    init(from decoder: Decoder) throws { fields = try decoder.singleValueContainer().decode([String: NativeJSON].self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(fields) }
    private func value(_ path: String) -> NativeJSON? {
        var value: NativeJSON = .object(fields)
        for key in path.split(separator: ".") {
            guard case .object(let object) = value, let next = object[String(key)] else { return nil }
            value = next
        }
        return value
    }
    func string(_ path: String) -> String? {
        guard case .string(let v) = value(path) else { return nil }; return v
    }
    func tokens(_ path: String) -> Int? {
        guard case .number(let v) = value(path), v >= 0, v <= 9_007_199_254_740_991 else { return nil }
        let n = NSDecimalNumber(decimal: v).int64Value
        return Decimal(n) == v ? Int(n) : nil
    }
    func milliseconds(_ path: String) -> Double? {
        guard case .number(let v) = value(path) else { return nil }
        let ms = NSDecimalNumber(decimal: v).doubleValue
        return ms.isFinite && ms >= 0 && ms <= 9_007_199_254_740_991 ? ms : nil
    }
    var id: String { string("requestID") ?? "unknown" }
    var turnID: String? { string("turnID") }
    var validIdentity: Bool { id != "unknown" && id.count <= 128 && turnID != nil && turnID!.count <= 128 }
    var stage: String { string("stage") ?? "unknown" }
    var isFinished: Bool { ["modelCompleted", "failed", "cancelled", "interrupted", "superseded"].contains(stage) }
    var inputKind: String { string("budget.input.kind") ?? "unknown" }
    var inputTokens: Int? { ["exact", "estimated"].contains(inputKind) ? tokens("budget.input.tokens") : nil }
    var capacity: Int? { tokens("budget.capabilities.capacity.tokens").flatMap { $0 > 0 ? $0 : nil } }
    var reserve: Int? { tokens("budget.outputReserve") }
    var fraction: Double? {
        guard let input = inputTokens, let capacity, let reserve else { return nil }
        return (Double(input) + Double(reserve)) / Double(capacity)
    }
    var remaining: Int? {
        guard let input = inputTokens, let capacity, let reserve else { return nil }
        return capacity - input - reserve
    }
    mutating func interrupt() {
        guard !isFinished else { return }
        fields["stage"] = .string("interrupted"); fields["code"] = .string("HOST_RESTARTED")
    }
    static let knownStages: Set<String> = Set("accepted restoring ready preparing measuring measured requesting headers firstData firstReasoning firstText modelCompleted toolStarted toolCompleted toolFailed persisting cancellationRequested completed cancelled failed queued steered turnCompleted interrupted superseded".split(separator: " ").map(String.init))
    /// Removes controls and bounds display of unfamiliar protocol names.
    static func label(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(96))
    }
}

extension NativeRequestInfo {
    var contextLabel: String {
        guard let inputTokens else { return "Context unknown" }
        let prefix = inputKind == "estimated" ? "≈" : ""
        let limit = capacity.map { $0.formatted() } ?? "?"
        return "Context " + prefix + inputTokens.formatted() + " / " + limit
    }
    var stageLabel: String {
        switch stage {
        case "preparing": return "Preparing"
        case "measuring", "measured": return "Measuring context"
        case "requesting": return "Waiting for model"
        case "headers", "firstData": return "Receiving response"
        case "firstReasoning": return "Reasoning"
        case "firstText": return "Responding"
        case "modelCompleted": return "Response complete"
        case "superseded": return "Preparation complete; not sent"
        case "failed": return "Request failed"
        case "cancelled": return "Stopped"
        case "interrupted": return "Interrupted"
        default: return "Unknown stage"
        }
    }
    var diagnosticExport: String {
        // Explicit scalar allowlist: never serialize the preserved raw object.
        let strings = ["requestID", "turnID", "purpose", "stage", "code", "budget.input.kind", "budget.input.source",
                       "budget.capabilities.capacity.source", "budget.capabilities.inputCounting", "budget.countIssue"]
        let counts = ["budget.input.tokens", "budget.outputReserve", "budget.capabilities.capacity.tokens",
                      "usage.promptTokens", "usage.completionTokens", "usage.totalTokens", "usage.cachedTokens", "usage.reasoningTokens"]
        let timings = ["elapsedMS", "preparationMS", "measurementMS", "responseHeadersMS", "firstDataMS", "firstReasoningMS", "firstTextMS", "modelCompletedMS"]
        var clean: [String: NativeJSON] = ["schemaVersion": .number(1)]
        let symbols = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        for key in strings {
            if let text = string(key), !text.isEmpty, text.count <= 128,
               text.unicodeScalars.allSatisfy({ symbols.contains($0) }) { clean[key] = .string(text) }
        }
        for key in counts { if let value = tokens(key) { clean[key] = .number(Decimal(value)) } }
        for key in timings { if let value = milliseconds(key) { clean[key] = .number(Decimal(value)) } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(clean)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
