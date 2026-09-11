import Foundation

// Typed view over the Host's per-key Session projections streamed on the
// `session/control` control stream. Self-contained value types only: no
// PocketStore, no SwiftUI/UIKit, no concurrency annotations, so the offline
// checks can compile this file on its own.
//
// Wire shapes mirror the shipped Host packages; value names below cite the
// declaration each model reads, so a later change has one place to look.

// MARK: - Value models

/// `title` — `dsh-session-title`: a plain string, or null before the first title.
/// A host that still ships the older `{ title }` wrapper also resolves.
struct SessionTitle: Equatable {
    var text = ""
    init(_ value: JSON = .null) {
        text = value.string.isEmpty ? value["title"].string : value.string
    }
}

/// `modelSelection` — `dsh-session-controller`: `{ lastUsed, next }`.
/// `next` is the selection the following request uses.
struct ModelSelectionProjection: Equatable {
    var next: JSON = .null
    var provider = ""
    var model = ""
    var effort = ""
    var hasSelection: Bool { !provider.isEmpty || !model.isEmpty }
    init(_ value: JSON = .null) {
        let selection = value["next"] == .null ? value["lastUsed"] : value["next"]
        next = selection
        provider = selection["provider"].string
        model = selection["model"].string
        effort = selection["reasoningEffort"].string
    }
}

/// `sessionListMetadata` — `dsh-session-controller`: cold-summary hints.
struct SessionListMetadata: Equatable {
    var blank = false
    var lastPromptAt: Double = 0
    init(_ value: JSON = .null) {
        blank = value["blank"].bool
        lastPromptAt = value["lastPromptAt"].double
    }
}

/// `permissions` — `dsh-permission-presets`: every switchable preset and the
/// effective current value. Key absence means no permission service is composed.
struct PermissionSelect: Equatable {
    struct Option: Equatable {
        var value = ""
        var name = ""
        var description = ""
    }
    var options: [Option] = []
    var currentValue = ""
    init(_ value: JSON = .null) {
        options = value["options"].array.map { Option(value: $0["value"].string, name: $0["name"].string, description: $0["description"].string) }
        currentValue = value["currentValue"].string
    }
}

/// `plan` — `dsh-plan-mode`: the logged mode in force and an outstanding selection.
struct PlanProjection: Equatable {
    var active = false
    var pending = false
    init(_ value: JSON = .null) {
        active = value["active"].bool
        pending = value["pending"].bool
    }
}

/// `goal` — `dsh-goal`: the current snapshot plus admitted rounds, or null.
struct GoalProjection: Equatable {
    var objective = ""
    var phase = ""
    var roundsStarted = 0
    var maxGoalRounds = 0
    var blockedReason = ""
    var present = false
    init(_ value: JSON = .null) {
        guard !value.object.isEmpty else { return }
        present = true
        let goal = value["goal"]
        objective = goal["objective"].string
        phase = goal["phase"].string
        maxGoalRounds = goal["maxGoalRounds"].int
        blockedReason = goal["blockedReason"]["message"].string
        roundsStarted = value["roundsStarted"].int
    }
}

/// `todos` — `dsh-tool-todo`: the whole list, or null before the first write.
struct TodoItem: Equatable {
    var content = ""
    var status = ""
    init(_ value: JSON = .null) {
        content = value["content"].string
        status = value["status"].string
    }
}

/// `sessionStats` — `dsh-session-stats`: whole-log counts and wall times.
struct SessionStatsProjection: Equatable {
    var turns = 0
    var steps = 0
    var llmMs = 0
    var toolMs = 0
    init(_ value: JSON = .null) {
        turns = value["turns"].int
        steps = value["steps"].int
        llmMs = value["llmMs"].int
        toolMs = value["toolMs"].int
    }
}

/// `tokenUsage` — `dsh-token-meter`: disjoint durable usage buckets.
/// Reasoning tokens are already included in `outputTokens`.
struct TokenUsageProjection: Equatable {
    var uncachedInputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    init(_ value: JSON = .null) {
        uncachedInputTokens = value["uncachedInputTokens"].int
        outputTokens = value["outputTokens"].int
        cacheReadTokens = value["cacheReadTokens"].int
        cacheWriteTokens = value["cacheWriteTokens"].int
    }
}

/// `contextBreakdown` — `dsh-token-meter`: heuristic composition of the next
/// request. These three figures are approximations and do not sum to the
/// provider-anchored `projectedTokens`.
struct ContextBreakdownProjection: Equatable {
    var systemTokens = 0
    var toolsTokens = 0
    var messageTokens = 0
    init(_ value: JSON = .null) {
        systemTokens = value["systemTokens"].int
        toolsTokens = value["toolsTokens"].int
        messageTokens = value["messageTokens"].int
    }
}

/// `contextPressure` — `dsh-token-meter`: last-wins pressure paired with the
/// newest known capacity. Any field may be absent and is then unknown, not zero.
struct ContextPressureProjection: Equatable {
    var pressureTokens = 0
    var projectedTokens = 0
    var contextWindow = 0
    var hasPressure: Bool { pressureTokens > 0 }
    var hasWindow: Bool { contextWindow > 0 }
    var percent: Double { hasPressure && hasWindow ? Double(pressureTokens) / Double(contextWindow) : 0 }
    var used: Int { pressureTokens }
    var limit: Int { contextWindow }
    init(_ value: JSON = .null) {
        pressureTokens = value["pressureTokens"].int
        projectedTokens = value["projectedTokens"].int
        contextWindow = value["contextWindow"].int
    }
}

/// `turnOutline` — `dsh-session-turn-outline`: one entry per started turn.
struct TurnOutlineProjection: Equatable {
    struct Entry: Equatable {
        var turn = 0
        var seq = 0
        var prompt = ""
        var response = ""
    }
    var turns: [Entry] = []
    init(_ value: JSON = .null) {
        turns = value.array.map { Entry(turn: $0["turn"].int, seq: $0["seq"].int, prompt: $0["prompt"].string, response: $0["response"].string) }
    }
}

/// `schedule` — `dsh-schedule`: active reminders. The entry union (`after`,
/// `at`, `every`) is not modelled yet; the record count is all the client reads.
struct ScheduleProjection: Equatable {
    var count = 0
    init(_ value: JSON = .null) {
        count = value.array.count
    }
}

/// `agentPreset` — `dsh-agent-presets`: the running preset, or null when the
/// deployment composes none.
struct AgentPresetProjection: Equatable {
    var name = ""
    var present = false
    init(_ value: JSON = .null) {
        name = value.string
        present = !value.object.isEmpty || !name.isEmpty
    }
}

/// `inbox` — `dsh-agent`: pending input per injection point.
/// The entries carry opaque replay JSON, so only the counts are modelled.
struct InboxProjection: Equatable {
    var nextTurn = 0
    var nextStep = 0
    init(_ value: JSON = .null) {
        nextTurn = value["next-turn"].array.count
        nextStep = value["next-step"].array.count
    }
}

// Keys the Host declares whose values the client does not read yet. They stay
// in the store as raw JSON (never dropped, never guessed at): `subagentCatalog`,
// `subagentTiming` and `subagent` carry subagent identity and timing,
// `jobs`-adjacent job state arrives on the C3 control frame, and the
// `turnBoundary` folds stay unmodelled until a view needs them.

/// One session's baseline block: complete values at an exact event cursor.
/// Omitted keys are absent capabilities at that cut.
struct ProjectionBaseline {
    var asOfSeq = 0
    var values: [String: JSON] = [:]
    init(_ value: JSON = .null) {
        asOfSeq = value["asOfSeq"].int
        values = value["values"].object
    }
}

// MARK: - Seq bookkeeping

/// One applied projection row: the whole value the Host computed and the
/// watermark of the unit that emitted it.
struct ProjectionRow: Equatable {
    var value: JSON
    var seq: Int
}

/// Per-session typed projection store with the shipped `session/control`
/// semantics (see the reference client's `apply` / `seed` / `truncate`).
/// A key that is absent means the capability is absent, never a default value.
struct SessionProjectionStore: Equatable {
    private(set) var rows: [String: ProjectionRow] = [:]

    /// Apply one finished value. A row already at this key with an equal or
    /// higher watermark wins; a stale or replayed frame changes nothing.
    mutating func apply(key: String, value: JSON, seq: Int) {
        if let row = rows[key], seq <= row.seq { return }
        rows[key] = ProjectionRow(value: value, seq: seq)
    }

    /// Seed from a baseline block. Every carried key lands under the same seq
    /// rule, then a key the block omits is capability-absent as of the cut: its
    /// row clears unless a newer frame already superseded the cut, so a stale
    /// baseline can neither overwrite nor clear newer values.
    mutating func seed(baseline: ProjectionBaseline) {
        for (key, value) in baseline.values { apply(key: key, value: value, seq: baseline.asOfSeq) }
        for (key, row) in rows where baseline.values[key] == nil && row.seq <= baseline.asOfSeq { rows.removeValue(forKey: key) }
    }

    /// Drop rows beyond a replacement control baseline. Such rows describe
    /// process state the Host lost before persisting it and would otherwise
    /// outrank recomputed lower-seq values forever. The caller seeds the new
    /// baseline immediately afterwards.
    mutating func truncate(lastSeq: Int) {
        for (key, row) in rows where row.seq > lastSeq { rows.removeValue(forKey: key) }
    }

    mutating func reset() { rows = [:] }

    /// The whole value at this key, or nil when the capability is absent.
    func value(_ key: String) -> JSON? { rows[key]?.value }

    /// Typed read of a modelled key. The reader is applied to the decoded row,
    /// so absence stays distinguishable from a decoded default.
    func value<T>(_ key: String, _ read: (JSON) -> T) -> T? { rows[key].map { read($0.value) } }

    var title: SessionTitle? { value(ProjectionKey.title) { SessionTitle($0) } }
    var modelSelection: ModelSelectionProjection? { value(ProjectionKey.modelSelection) { ModelSelectionProjection($0) } }
    var imageLimits: ImageLimits? { value(ProjectionKey.imageLimits) { ImageLimits($0) } }
    var permissions: PermissionSelect? { value(ProjectionKey.permissions) { PermissionSelect($0) } }
    var plan: PlanProjection? { value(ProjectionKey.plan) { PlanProjection($0) } }
    var goal: GoalProjection? { value(ProjectionKey.goal) { GoalProjection($0) } }
    var todos: [TodoItem]? { rows[ProjectionKey.todos].map { TodoItem.list($0.value) } }
    var sessionStats: SessionStatsProjection? { value(ProjectionKey.sessionStats) { SessionStatsProjection($0) } }
    var tokenUsage: TokenUsageProjection? { value(ProjectionKey.tokenUsage) { TokenUsageProjection($0) } }
    var contextBreakdown: ContextBreakdownProjection? { value(ProjectionKey.contextBreakdown) { ContextBreakdownProjection($0) } }
    var contextPressure: ContextPressureProjection? { value(ProjectionKey.contextPressure) { ContextPressureProjection($0) } }
    var turnOutline: TurnOutlineProjection? { value(ProjectionKey.turnOutline) { TurnOutlineProjection($0) } }
    var schedule: ScheduleProjection? { value(ProjectionKey.schedule) { ScheduleProjection($0) } }
    var agentPreset: AgentPresetProjection? { value(ProjectionKey.agentPreset) { AgentPresetProjection($0) } }
    var inbox: InboxProjection? { value(ProjectionKey.inbox) { InboxProjection($0) } }
    var sessionListMetadata: SessionListMetadata? { value(ProjectionKey.sessionListMetadata) { SessionListMetadata($0) } }
}

extension TodoItem {
    /// `todos` is a whole list or null; a malformed value degrades to empty.
    static func list(_ value: JSON = .null) -> [TodoItem] { value.array.map { TodoItem($0) } }
}

/// The projection keys the client reads by name.
enum ProjectionKey {
    static let title = "title"
    static let modelSelection = "modelSelection"
    static let imageLimits = "imageLimits"
    static let permissions = "permissions"
    static let plan = "plan"
    static let goal = "goal"
    static let todos = "todos"
    static let sessionStats = "sessionStats"
    static let tokenUsage = "tokenUsage"
    static let contextBreakdown = "contextBreakdown"
    static let contextPressure = "contextPressure"
    static let turnOutline = "turnOutline"
    static let schedule = "schedule"
    static let agentPreset = "agentPreset"
    static let inbox = "inbox"
    static let sessionListMetadata = "sessionListMetadata"
}
