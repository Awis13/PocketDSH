import Foundation

// The rc.1 Remote wire contract is extensible; retain unknown JSON in tool details.
indirect enum JSON: Codable, Equatable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([JSON].self) { self = .array(x) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    // JavaScript can serialize an unpaired UTF-16 surrogate after truncating a
    // title with slice(). Foundation rejects the entire response in that case.
    // Replace only lone surrogate escapes; preserve pairs and literal \\u text.
    static func decodeWire(_ data: Data) throws -> JSON {
        let bytes = Array(data)
        var output: [UInt8] = []; output.reserveCapacity(bytes.count)
        var i = 0, inString = false
        func unicodeEscape(at offset: Int) -> Int? {
            guard offset + 5 < bytes.count, bytes[offset] == 92, bytes[offset + 1] == 117 else { return nil }
            var value = 0
            for byte in bytes[(offset + 2)...(offset + 5)] {
                let digit: Int
                switch byte {
                case 48...57: digit = Int(byte - 48)
                case 65...70: digit = Int(byte - 65) + 10
                case 97...102: digit = Int(byte - 97) + 10
                default: return nil
                }
                value = value * 16 + digit
            }
            return value
        }
        while i < bytes.count {
            if bytes[i] == 34 { inString.toggle() }
            if inString, bytes[i] == 92, i + 1 < bytes.count {
                if let unit = unicodeEscape(at: i), (0xD800...0xDFFF).contains(unit) {
                    if unit <= 0xDBFF, let low = unicodeEscape(at: i + 6), (0xDC00...0xDFFF).contains(low) {
                        output.append(contentsOf: bytes[i..<(i + 12)]); i += 12
                    } else {
                        output.append(contentsOf: [92, 117, 102, 102, 102, 100]); i += 6
                    }
                } else {
                    output.append(contentsOf: bytes[i...(i + 1)]); i += 2
                }
            } else { output.append(bytes[i]); i += 1 }
        }
        return try JSONDecoder().decode(JSON.self, from: Data(output))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSON { object[key] ?? .null }
    var object: [String: JSON] { if case .object(let x) = self { return x }; return [:] }
    var array: [JSON] { if case .array(let x) = self { return x }; return [] }
    var string: String { if case .string(let x) = self { return x }; return "" }
    var int: Int { if case .number(let x) = self { return Int(x) }; return 0 }
    var double: Double { if case .number(let x) = self { return x }; return 0 }
    var bool: Bool { if case .bool(let x) = self { return x }; return false }
    var pretty: String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: e.encode(self), as: UTF8.self)) ?? ""
    }
    static func images(_ blocks: JSON) -> [JSON] {
        blocks.array.filter { $0["type"].string == "image" && !$0["attachment"]["attachmentId"].string.isEmpty }.map { $0["attachment"] }
    }
    static func text(_ blocks: JSON) -> String {
        blocks.array.compactMap { b in
            b["type"].string == "text" ? b["text"].string : b["type"].string == "image" ? "[Image]" : nil
        }.joined(separator: "\n")
    }
}

struct HarnessSession: Identifiable {
    var raw: JSON
    var id: String { raw["sessionId"].string }
    var running: Bool { raw["running"].bool }
    var cwd: String { raw["cwd"].string }
    var title: String {
        let title = raw["projections"]["values"]["title"]
        return [title.string, title["title"].string].first(where: { !$0.isEmpty }) ?? "New task"
    }
    var date: Date { Date(timeIntervalSince1970: raw["updatedAt"].double / 1000) }
}
struct HarnessWorkspace: Identifiable {
    var raw: JSON
    var id: String { raw["workspaceId"].string }
    var title: String { raw["title"].string }
    var sessionIDs: [String] { raw["sessionIds"].array.map(\.string) }
}
struct Interaction: Identifiable {
    let raw: JSON
    let clientID: String
    var id: String { raw["eventId"].string }
    var sessionID: String { raw["agentId"].string }
    var isApproval: Bool { raw["event"].string == "approval/request" }
    var request: JSON { raw["request"] }
}
struct NativeStyledRun: Equatable {
    var text: String
    var foreground: Int?
    var background: Int?
    // Preserve ANSI palette references so retained output can follow the theme.
    // RGB values above are only for explicit 256/truecolor output.
    var foregroundIndex: Int?
    var backgroundIndex: Int?
    var bold = false
    var underline = false
    var dim = false
    var italic = false
    var crossedOut = false
    var inverse = false

    func hasSameStyle(as other: Self) -> Bool {
        foreground == other.foreground && background == other.background &&
        foregroundIndex == other.foregroundIndex && backgroundIndex == other.backgroundIndex &&
        bold == other.bold && underline == other.underline && dim == other.dim &&
        italic == other.italic && crossedOut == other.crossedOut && inverse == other.inverse
    }
}

struct NativeBlock: Identifiable, Equatable {
    let id: String
    var command: String
    var directory: String
    var output = Data()
    var preview = ""
    var styledOutput: [NativeStyledRun] = []
    var exitCode: Int?
    var finished = false
    var interrupted = false
    var truncated = false
}

struct TranscriptRow: Identifiable, Equatable {
    enum Kind { case user, assistant, reasoning, tool, shell, notice }
    var id: String
    var kind: Kind
    var text: String
    var detail = ""
    var complete = true
    var failed = false
    var images: [JSON] = []
    var diffs: [JSON] = []
    var shell: NativeBlock?
}

// MARK: - Command lifecycle fold

/// `CommandResult` as the durable `command/done` event carries it. `kind` is
/// "success" or "error"; `text` is the handler's verbatim outcome when it
/// produced one.
struct CommandOutcome: Equatable {
    var kind = ""
    var text: String?
    var sourceEventSeq: Int?
    var isError: Bool { kind == "error" }
}

/// One paired command lifecycle record: `command/run` opens it and the
/// `command/done` with the same commandId settles it - the web chat's command
/// node (dsh-client-ui-chat client.js:5713-5743 commandFromRun /
/// commandFromDone). `seq` and `name`/`args` stay at the run's values, so a
/// settled command keeps its place and its invocation.
struct CommandRecord: Equatable {
    var commandId = ""
    var seq = 0
    var name: String?
    var args: String?
    var outcome: CommandOutcome?
    var settled: Bool { outcome != nil }
    /// The invocation as a composer line: "/name" plus the recorded raw input.
    var invocation: String? { name.map { "/" + $0 + (args ?? "") } }
}

/// The incremental fold over one session's durable event stream, in arrival
/// order. Both lifecycle events are log-only appends on the Host, so the fold
/// is the only durable source for a command's outcome - it survives reconnect
/// and restart because it is recomputed from the transcript, and duplicate,
/// re-delivered and out-of-order frames land on the same record.
struct CommandLifecycleFold {
    private(set) var records: [CommandRecord] = []
    private var indexByCommandId: [String: Int] = [:]

    /// Fold one event. An event that is not a command lifecycle frame changes
    /// nothing and reports nil; otherwise the affected record's index.
    @discardableResult
    mutating func apply(_ event: JSON) -> Int? {
        let type = event["type"].string
        guard type == "command/run" || type == "command/done" else { return nil }
        let data = event["data"], commandId = data["commandId"].string
        guard !commandId.isEmpty else { return nil }
        if type == "command/run" {
            // A re-delivered run never reopens a settled command: its payload
            // is already known, and the outcome is the newer fact.
            if let i = indexByCommandId[commandId] {
                if records[i].name == nil {
                    records[i].name = data["name"].string
                    if case .string(let args) = data["args"] { records[i].args = args }
                }
                return i
            }
            var record = CommandRecord(commandId: commandId, seq: event["seq"].int)
            record.name = data["name"].string
            if case .string(let args) = data["args"] { record.args = args }
            return append(record)
        }
        // command/done: a success may point at the authoritative domain event;
        // an error's seq would be meaningless, so the reference drops it.
        let kind = data["kind"].string
        var outcome = CommandOutcome(kind: kind)
        if case .string(let text) = data["text"] { outcome.text = text }
        if kind == "success", case .number = data["sourceEventSeq"] {
            let seq = data["sourceEventSeq"].int
            if seq >= 0 { outcome.sourceEventSeq = seq }
        }
        if let i = indexByCommandId[commandId] {
            records[i].outcome = outcome
            return i
        }
        // A done whose run sits outside the loaded window still renders; the
        // reference's fallback node carries no name either.
        return append(CommandRecord(commandId: commandId, seq: event["seq"].int, outcome: outcome))
    }

    /// The record one commandId folded to, if any.
    func record(_ commandId: String) -> CommandRecord? {
        indexByCommandId[commandId].map { records[$0] }
    }

    private mutating func append(_ record: CommandRecord) -> Int {
        records.append(record)
        let i = records.count - 1
        indexByCommandId[record.commandId] = i
        return i
    }
}

/// One command's transcript row: the invocation plus its settled state. A
/// command whose done has not landed yet reads as running, exactly like the
/// reference card's null outcome.
func commandRow(_ record: CommandRecord) -> TranscriptRow {
    let invocation = record.invocation ?? "Command"
    let state = record.outcome.map { $0.text ?? ($0.isError ? "failed" : "done") } ?? "running"
    return TranscriptRow(id: "command-" + record.commandId, kind: .notice,
                         text: invocation + " - " + state,
                         detail: record.outcome?.text ?? "",
                         complete: record.settled, failed: record.outcome?.isError == true)
}

// Fold the human transcript, preserving historical messages across compaction.
// Final assistant messages replace their own streaming blocks, never earlier turns.
struct Transcript {
    private(set) var events: [JSON] = []
    private(set) var cursor = -1
    mutating func replace(_ records: [JSON], cursor: Int) {
        events = records.map { $0["event"] }; self.cursor = cursor
    }
    mutating func prepend(_ records: [JSON]) {
        let existing = Set(events.map { $0["seq"].int })
        events = records.map { $0["event"] }.filter { !existing.contains($0["seq"].int) } + events
    }
    mutating func append(_ event: JSON) -> Bool {
        let seq = event["seq"].int
        if seq <= cursor { return true }
        guard seq == cursor + 1 else { return false }
        events.append(event); cursor = seq; return true
    }
    var firstSeq: Int? { events.first?["seq"].int }
    var rows: [TranscriptRow] {
        var rows: [TranscriptRow] = []
        func blockID(_ d: JSON) -> String { "a-\(d["turn"].int)-\(d["step"].int)" }
        func appendDelta(_ id: String, _ kind: TranscriptRow.Kind, _ text: String) {
            if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].text += text }
            else { rows.append(.init(id: id, kind: kind, text: text, complete: false)) }
        }
        // Command lifecycle frames are durable log-only appends: their row is
        // the fold's record, placed at the run's position and settled in place
        // by the paired done, so a reload rebuilds the same row.
        var commands = CommandLifecycleFold()
        func foldCommand(_ event: JSON) {
            let commandId = event["data"]["commandId"].string
            guard commands.apply(event) != nil, let record = commands.record(commandId) else { return }
            let row = commandRow(record)
            // Locate the row by its stable id: later frames prune and reorder
            // `rows` (assistant/message drops streamed deltas), so an index
            // captured at the run would settle the wrong command.
            if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i] = row }
            else { rows.append(row) }
        }
        for e in events {
            let d = e["data"], type = e["type"].string, seq = e["seq"].int
            switch type {
            case "command/run", "command/done":
                foldCommand(e)
            case "user/message":
                if d["source"]["kind"].string == "user" {
                    rows.append(.init(id: "u-\(seq)", kind: .user, text: d["content"].array.filter { $0["type"].string == "text" }.map { $0["text"].string }.joined(separator: "\n"), images: d["content"].array.filter { $0["type"].string == "image" }.map { $0["attachment"] }))
                }
            case "assistant/chunk":
                let c = d["chunk"], kind = c["type"].string
                if kind == "text-delta" || kind == "reasoning-delta" {
                    appendDelta(blockID(d) + "-\(c["index"].int)", kind == "text-delta" ? .assistant : .reasoning, c["text"].string)
                }
            case "chunkrow/text-chunks", "chunkrow/reasoning-chunks":
                appendDelta(blockID(d) + "-\(d["index"].int)", type == "chunkrow/text-chunks" ? .assistant : .reasoning, d["texts"].array.map(\.string).joined())
            case "assistant/message":
                let prefix = blockID(d) + "-"
                rows.removeAll { $0.id.hasPrefix(prefix) }
                for (i, b) in d["message"]["content"].array.enumerated() {
                    let kind = b["type"].string
                    if kind == "text" || kind == "reasoning" {
                        rows.append(.init(id: prefix + "\(i)", kind: kind == "text" ? .assistant : .reasoning,
                                          text: b["text"].string, complete: true))
                    } else if kind == "image", !b["attachment"]["attachmentId"].string.isEmpty {
                        rows.append(.init(id: prefix + "\(i)", kind: .assistant, text: "", images: [b["attachment"]]))
                    }
                }
                if d["interrupted"].bool { rows.append(.init(id: "i-\(seq)", kind: .notice, text: "Response stopped")) }
            case "tool/call":
                rows.append(.init(id: "tool-" + d["callId"].string, kind: .tool, text: d["name"].string, detail: d["arguments"].string, complete: false))
            case "tool/result":
                let m = d["message"]
                let results = m["content"].array.filter { $0["type"].string == "tool-result" }
                let id = "tool-" + m["source"]["callId"].string
                // History pages may start with a result whose call is on an older page.
                if !rows.contains(where: { $0.id == id }) {
                    rows.append(.init(id: id, kind: .tool, text: "Tool result"))
                }
                if let i = rows.firstIndex(where: { $0.id == id }) {
                    rows[i].detail += "\n\n" + results.map { JSON.text($0["content"]) }.joined(separator: "\n")
                    rows[i].images = results.flatMap { JSON.images($0["content"]) }
                    rows[i].diffs = d["meta"]["diffs"].array
                    rows[i].complete = true
                    rows[i].failed = d["error"] != .null || results.contains { $0["isError"].bool }
                }
            case "turn/error": rows.append(.init(id: "error-\(seq)", kind: .notice, text: d.pretty, failed: true))
            default: break
            }
        }
        return rows.filter { !$0.text.isEmpty || !$0.images.isEmpty }
    }
}

// DSH alpha.2 separates live presentation frames from the durable transcript.
struct AssistantLiveStream {
    private var attempt = ""
    private var nextIndex = 0
    private var turn = 0
    private var step = 0
    private(set) var rows: [TranscriptRow] = []
    mutating func baseline(_ value: JSON) {
        self = AssistantLiveStream()
        let active = value["activeAttempt"]
        guard active != .null else { return }
        attempt = active["attemptId"].string; turn = active["turn"].int; step = active["step"].int
        nextIndex = active["nextIndex"].int
        for item in active["stream"].array {
            if item["type"].string == "chunk" { chunk(item["chunk"]) }
            else if ["text-chunks", "reasoning-chunks"].contains(item["type"].string) {
                chunk(.object(["type": .string(item["type"].string == "text-chunks" ? "text-delta" : "reasoning-delta"), "index": item["index"], "text": .string(item["texts"].array.map(\.string).joined())]))
            }
        }
    }
    mutating func receive(_ frame: JSON) -> Bool {
        switch frame["type"].string {
        case "start":
            self = AssistantLiveStream(); attempt = frame["attemptId"].string
            turn = frame["turn"].int; step = frame["step"].int
        case "chunk":
            guard frame["attemptId"].string == attempt else { return false }
            let index = frame["index"].int
            if index < nextIndex { return true }
            guard index == nextIndex else { return false }
            nextIndex += 1; chunk(frame["chunk"])
        case "end":
            if frame["attemptId"].string == attempt { rows = [] }
        default: break
        }
        return true
    }
    private mutating func chunk(_ c: JSON) {
        guard ["text-delta", "reasoning-delta"].contains(c["type"].string) else { return }
        let id = "a-\(turn)-\(step)-\(c["index"].int)"
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].text += c["text"].string }
        else { rows.append(TranscriptRow(id: id, kind: c["type"].string == "text-delta" ? .assistant : .reasoning, text: c["text"].string, complete: false)) }
    }
    func merged(with durable: [TranscriptRow]) -> [TranscriptRow] {
        let ids = Set(durable.map(\.id)); return durable + rows.filter { !ids.contains($0.id) }
    }
}
