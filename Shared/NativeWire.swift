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
    var mode: String?
    var action: String?
    var itemID: String?
    var base: String?
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
    var capabilities: [String]?
    var compaction: NativeCompactionInfo?
    var queue: NativeQueueInfo?
    var diff: NativeDiffInfo?
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
        capabilities = try c.decodeIfPresent([String].self, forKey: NativeWireKey("capabilities"))
        compaction = try? c.decodeIfPresent(NativeCompactionInfo.self, forKey: NativeWireKey("compaction"))
        queue = try? c.decodeIfPresent(NativeQueueInfo.self, forKey: NativeWireKey("queue"))
        diff = try? c.decodeIfPresent(NativeDiffInfo.self, forKey: NativeWireKey("diff"))
        let known: Set<String> = ["op", "session", "id", "text", "bytes", "stage", "model", "workspace", "ptyID", "chats", "approval", "running", "gap", "sequence", "exitCode", "arguments", "failed", "sessions", "rows", "columns", "candidates", "limited", "request", "capabilities", "compaction", "queue", "diff"]
        for key in c.allKeys where !known.contains(key.stringValue) || (key.stringValue == "request" && request == nil) || (key.stringValue == "compaction" && compaction == nil) || (key.stringValue == "queue" && queue == nil) || (key.stringValue == "diff" && diff == nil) {
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
        try c.encodeIfPresent(capabilities, forKey: NativeWireKey("capabilities"))
        try c.encodeIfPresent(compaction, forKey: NativeWireKey("compaction"))
        try c.encodeIfPresent(queue, forKey: NativeWireKey("queue"))
        try c.encodeIfPresent(diff, forKey: NativeWireKey("diff"))
    }
}

extension NativeEvent {
    /// Acknowledgement of the user's own submission. It carries the session it
    /// was sent to and must still be applied after the user switches sessions,
    /// otherwise `nativeSubmission`/`pendingRequest` would never clear and every
    /// later send would stay blocked. Every other scoped event, including
    /// `error`/`queueRejected`, belongs to the currently selected session.
    var appliesRegardlessOfSelection: Bool { op == "accepted" }

    /// Whether this event may be processed while `selected` is on screen.
    /// Session-less events are host-wide; a nil `selected` admits only those.
    func deliversToSelection(_ selected: String?) -> Bool {
        appliesRegardlessOfSelection || session == nil || session == selected
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

/// Foundation-only view of the durable core receipt. Preserve future fields.
struct NativeCompactionInfo: Codable, Sendable, Equatable, Identifiable {
    static let capability = "context.compact.v1"
    var metadata: NativeRequestInfo
    init(id: String, state: String, code: String? = nil) {
        var fields: [String: NativeJSON] = ["operationID": .string(id), "state": .string(state)]
        if let code { fields["code"] = .string(code) }
        metadata = NativeRequestInfo(fields: fields)
    }
    init<T: Encodable>(encoding value: T) throws {
        metadata = try NativeRequestInfo(encoding: value)
    }
    init(from decoder: Decoder) throws { metadata = try NativeRequestInfo(from: decoder) }
    func encode(to encoder: Encoder) throws { try metadata.encode(to: encoder) }
    var id: String { metadata.string("operationID") ?? "" }
    var state: String { metadata.string("state") ?? "unknown" }
    var code: String? { metadata.string("code") }
    var valid: Bool { !id.isEmpty && id.utf8.count <= 128 && !id.contains("\0") }
    var isRunning: Bool { state == "running" }
    var isFinished: Bool { ["completed", "failed", "cancelled", "interrupted"].contains(state) }
    var title: String {
        switch state {
        case "running": return "Compacting context"
        case "completed": return "Context compacted"
        case "cancelled": return "Compaction stopped"
        case "interrupted": return "Compaction interrupted"
        default: return "Context unchanged"
        }
    }
    func count(_ key: String) -> String {
        guard let value = metadata.tokens(key + ".input.tokens"),
              let kind = metadata.string(key + ".input.kind"), ["exact", "estimated"].contains(kind) else { return "unknown" }
        return (kind == "estimated" ? "≈" : "") + value.formatted()
    }
    var detail: String {
        if state == "completed" { return count("before") + " → " + count("after") + " input tokens" }
        switch code {
        case "BUSY": return "Wait for the current operation to finish, or use Stop."
        case "CONTEXT_CAPACITY_UNKNOWN": return "The host needs a known model context capacity."
        case "CONTEXT_NOTHING_TO_COMPACT": return "No older completed turns to compact yet."
        case "CONTEXT_PROTECTED_TAIL_TOO_LARGE": return "Recent turns alone exceed the context budget."
        case "CONTEXT_GROUP_TOO_LARGE": return "An older turn is too large to summarize safely."
        case "COMPACTION_INTERRUPTED": return "The host restarted. No compaction was restarted automatically."
        case "OPERATION_NOT_FOUND": return "The host has no receipt for this operation. You can start a new one."
        case "CANCELLED": return "Stopped; the conversation and previous context are preserved."
        case "COMPACTION_INVALID_SUMMARY", "COMPACTION_NOT_SMALLER", "CONTEXT_STILL_TOO_LARGE": return "The summary did not pass validation. Previous context is preserved."
        case .some(let code): return NativeRequestInfo.label(code)
        case nil: return isRunning ? "Preparing and validating a summary; history stays intact." : ""
        }
    }
    /// Only the ordinary editor owns slash controls; active terminal programs own raw input.
    static func isEditorCommand(_ text: String, terminalRunning: Bool = false) -> Bool {
        !terminalRunning && text.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact"
    }
}

/// One pending command as the client sees it. `preview` is bounded so a full
/// queue can never approach the host's per-message budget; `truncated` tells the
/// client not to prefill an editor from a clipped prompt.
struct NativeQueueItem: Codable, Sendable, Equatable, Identifiable {
    static let queued = "queued"
    static let steering = "steering"
    var id: String
    var preview: String
    var placement: String
    var truncated: Bool
    var valid: Bool {
        !id.isEmpty && id.utf8.count <= 128 && !id.contains("\0")
            && (placement == Self.queued || placement == Self.steering)
    }
    var isSteering: Bool { placement == Self.steering }
    var placementLabel: String { isSteering ? "Steers the current turn" : "Runs after the current turn" }
}

/// Additive session queue snapshot. The host recomputes it from the durable
/// inbox on attach and after every mutation instead of replaying stale copies,
/// so it is a projection of current state, never transcript history.
struct NativeQueueInfo: Codable, Sendable, Equatable {
    static let capability = "session.queue.v1"
    var items: [NativeQueueItem]
    var omitted: Int
    var count: Int { items.count + omitted }
    static func rejectionDetail(_ code: String) -> String {
        switch code {
        case "queue-item-not-found": return "That pending request is no longer queued."
        case "steer-unavailable": return "Steering is only available while a turn is running."
        case "queue-unavailable": return "The host could not read the pending queue. Try again."
        case "BUSY": return "Wait for the current operation to finish, or use Stop."
        default: return NativeRequestInfo.label(code)
        }
    }
}

/// Read-only workspace diff. A hunk mirrors the rendered `{path, oldText,
/// newText}` model: removed lines and added lines, no context. The host bounds
/// every field; the client re-clamps so an older or hostile host cannot inflate
/// a single frame.
struct NativeDiffHunk: Codable, Sendable, Equatable {
    var path: String
    var header: String
    var oldText: String
    var newText: String

    init(path: String, header: String, oldText: String, newText: String) {
        self.path = path; self.header = header; self.oldText = oldText; self.newText = newText
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        header = (try? c.decodeIfPresent(String.self, forKey: .header)) ?? ""
        oldText = (try? c.decodeIfPresent(String.self, forKey: .oldText)) ?? ""
        newText = (try? c.decodeIfPresent(String.self, forKey: .newText)) ?? ""
    }
    func clamped(maximumBytes: Int = NativeDiffLimits.maximumFieldBytes) -> NativeDiffHunk {
        var copy = self
        copy.path = NativeDiffInfo.prefixText(path, bytes: 1024)
        copy.header = NativeDiffInfo.prefixText(header, bytes: 256)
        copy.oldText = NativeDiffInfo.clampText(oldText, bytes: maximumBytes)
        copy.newText = NativeDiffInfo.clampText(newText, bytes: maximumBytes)
        return copy
    }
}

struct NativeDiffFile: Codable, Sendable, Equatable {
    var path: String
    var oldPath: String?
    var status: String
    var binary: Bool
    var additions: Int
    var deletions: Int
    var truncated: Bool
    var hunks: [NativeDiffHunk]

    init(path: String, oldPath: String? = nil, status: String, binary: Bool = false,
         additions: Int = 0, deletions: Int = 0, truncated: Bool = false, hunks: [NativeDiffHunk] = []) {
        self.path = path; self.oldPath = oldPath; self.status = status; self.binary = binary
        self.additions = additions; self.deletions = deletions; self.truncated = truncated; self.hunks = hunks
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        oldPath = try? c.decodeIfPresent(String.self, forKey: .oldPath)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "modified"
        binary = (try? c.decodeIfPresent(Bool.self, forKey: .binary)) ?? false
        additions = (try? c.decodeIfPresent(Int.self, forKey: .additions)) ?? 0
        deletions = (try? c.decodeIfPresent(Int.self, forKey: .deletions)) ?? 0
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        hunks = (try? c.decodeIfPresent([NativeDiffHunk].self, forKey: .hunks)) ?? []
    }
}

struct NativeDiffInfo: Codable, Sendable, Equatable {
    static let capability = "workspace.diff.v1"
    var base: String
    var resolvedBase: String?
    var files: [NativeDiffFile]
    var truncated: Bool
    var error: String?

    init(base: String, resolvedBase: String? = nil, files: [NativeDiffFile] = [], truncated: Bool = false, error: String? = nil) {
        self.base = base; self.resolvedBase = resolvedBase; self.files = files
        self.truncated = truncated; self.error = error
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = (try? c.decodeIfPresent(String.self, forKey: .base)) ?? "HEAD"
        resolvedBase = try? c.decodeIfPresent(String.self, forKey: .resolvedBase)
        files = (try? c.decodeIfPresent([NativeDiffFile].self, forKey: .files)) ?? []
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }

    var statusLabel: String {
        switch base {
        case "worktree": return "Working tree"
        case "staged": return "Staged"
        case "HEAD": return "Working tree vs HEAD"
        default: return "Branch vs " + base
        }
    }

    var summary: String {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        return "\(files.count) file\(files.count == 1 ? "" : "s"), +\(additions) −\(deletions)"
    }

    /// Re-clamps an incoming payload to the same hard bounds the host enforces.
    func sanitized(maximumFiles: Int = NativeDiffLimits.maximumFiles,
                   maximumHunksPerFile: Int = NativeDiffLimits.maximumHunksPerFile,
                   maximumTotalBytes: Int = NativeDiffLimits.maximumTotalBytes) -> NativeDiffInfo {
        var copy = self
        copy.base = NativeDiffInfo.prefixText(base, bytes: 200)
        copy.resolvedBase = resolvedBase.map { NativeDiffInfo.prefixText($0, bytes: 128) }
        copy.error = error.map { NativeDiffInfo.prefixText($0, bytes: 400) }
        var total = 0, clamped = truncated
        var result: [NativeDiffFile] = []
        for var file in files {
            guard result.count < maximumFiles else { clamped = true; break }
            file.path = NativeDiffInfo.prefixText(file.path, bytes: 1024)
            file.oldPath = file.oldPath.map { NativeDiffInfo.prefixText($0, bytes: 1024) }
            file.additions = max(0, file.additions)
            file.deletions = max(0, file.deletions)
            var hunks: [NativeDiffHunk] = []
            for hunk in file.hunks {
                guard hunks.count < maximumHunksPerFile else { file.truncated = true; clamped = true; break }
                let clampedHunk = hunk.clamped()
                let size = clampedHunk.oldText.utf8.count + clampedHunk.newText.utf8.count
                guard total + size <= maximumTotalBytes else { file.truncated = true; clamped = true; break }
                total += size
                if clampedHunk != hunk { clamped = true }
                hunks.append(clampedHunk)
            }
            file.hunks = hunks
            if file.truncated { clamped = true }
            result.append(file)
        }
        copy.files = result
        copy.truncated = clamped
        return copy
    }

    static func clampText(_ text: String, bytes: Int) -> String {
        var value = text
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > NativeDiffLimits.maximumLines { value = lines.prefix(NativeDiffLimits.maximumLines).joined(separator: "\n") }
        return value.utf8.count > bytes ? prefixText(value, bytes: bytes) : value
    }

    static func prefixText(_ text: String, bytes: Int) -> String {
        var end = text.startIndex, count = 0
        while end < text.endIndex {
            let next = text.index(after: end), size = text[end..<next].utf8.count
            guard count + size <= bytes else { break }
            count += size; end = next
        }
        return String(text[..<end])
    }
}

enum NativeDiffLimits {
    static let maximumFiles = 200
    static let maximumHunksPerFile = 200
    static let maximumFieldBytes = 16_384
    static let maximumLines = 300
    static let maximumTotalBytes = 262_144
}
