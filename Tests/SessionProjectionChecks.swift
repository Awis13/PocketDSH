import Foundation

// Stand-in for PocketDSH/ImageAttachments.swift, which pulls UIKit-adjacent
// ImageIO imports. The store's typed ImageLimits read only needs the same
// shape, so the check stays compilable beside HarnessProtocol + SessionProjection.
struct ImageLimits: Equatable {
    var maxBytes = 5 * 1024 * 1024
    var maxCount = 4
    init(_ value: JSON = .null) {
        if value["maxImageBytes"].int > 0 { maxBytes = min(maxBytes, value["maxImageBytes"].int) }
        if value["maxImagesPerMessage"].int > 0 { maxCount = min(maxCount, value["maxImagesPerMessage"].int) }
    }
}

@main struct SessionProjectionChecks {
    static func json(_ s: String) -> JSON { try! JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }
    static func main() {
        // Higher seq wins; an equal or lower seq is ignored, and apply
        // reports the refusal so callers can skip their downstream writes.
        var store = SessionProjectionStore()
        assert(store.apply(key: "title", value: .string("first"), seq: 4), "A new row lands")
        assert(store.title?.text == "first")
        assert(!store.apply(key: "title", value: .string("stale"), seq: 3), "A lower seq is refused")
        assert(store.title?.text == "first", "A lower seq must not overwrite")
        assert(!store.apply(key: "title", value: .string("tie"), seq: 4), "An equal seq is refused")
        assert(store.title?.text == "first", "An equal seq must be ignored")
        assert(store.apply(key: "title", value: .string("newer"), seq: 5), "A higher seq lands")
        assert(store.title?.text == "newer")
        print("PASS: higher-seq-wins and equal-seq-ignored")

        // The bug this commit fixes: a row the replacement baseline does not
        // account for must not survive it, however high its seq was.
        store.apply(key: "plan", value: json(#"{"active":true}"#), seq: 900)
        assert(store.plan?.active == true)
        store.truncate(lastSeq: 12)
        assert(store.value("plan") == nil, "A row beyond the replacement baseline must be dropped")
        store.seed(baseline: ProjectionBaseline(json(#"{"asOfSeq":12,"values":{"title":"recomputed"}}"#)))
        assert(store.title?.text == "recomputed")
        assert(store.plan == nil, "A truncated key stays absent after seeding")
        store.apply(key: "plan", value: json(#"{"active":false}"#), seq: 2)
        assert(store.plan?.active == false, "Recomputed lower-seq values apply once the high-seq row is gone")
        print("PASS: truncate drops rows a replacement baseline does not account for")

        // Seed applies every carried key at asOfSeq, then clears absent keys at
        // or below the cut while preserving newer ones.
        var seeded = SessionProjectionStore()
        seeded.apply(key: "goal", value: json(#"{"roundsStarted":1}"#), seq: 5)
        seeded.apply(key: "schedule", value: json("[]"), seq: 40)
        seeded.seed(baseline: ProjectionBaseline(json(#"{"asOfSeq":10,"values":{"title":"kept"}}"#)))
        assert(seeded.title?.text == "kept" && seeded.goal == nil)
        assert(seeded.value("schedule") != nil, "A row newer than the cut survives seeding")
        seeded.apply(key: "title", value: .string("stale"), seq: 1)
        assert(seeded.title?.text == "kept", "Seeded rows obey the seq rule afterwards")
        seeded.reset()
        assert(seeded.rows.isEmpty && seeded.value("title") == nil)
        print("PASS: seed applies asOfSeq values, clears absent stale keys, keeps newer rows, reset clears")

        // An unknown key is retained as raw JSON and never fails decoding; its
        // absence, not a default, is what a reader sees.
        var unknown = SessionProjectionStore()
        let future = json(#"{"nested":{"deep":[1,"two",null]},"flag":true}"#)
        unknown.apply(key: "turnBoundary", value: future, seq: 7)
        assert(unknown.value("turnBoundary") == future)
        assert(unknown.title == nil && unknown.contextPressure == nil, "Absent keys read as absent, not as defaults")
        let baseline = ProjectionBaseline(json(#"{"asOfSeq":7,"values":{"turnBoundary":{"openTurnStartSeq":3}}}"#))
        assert(baseline.values["turnBoundary"]?["openTurnStartSeq"].int == 3)
        assert(ProjectionBaseline(.null).asOfSeq == 0 && ProjectionBaseline(.null).values.isEmpty)
        print("PASS: unknown projection keys are retained as raw JSON, absent keys read as absent")

        // Each modelled key decodes a realistic fixture, and a missing or
        // malformed value degrades to the default instead of crashing.
        var typed = SessionProjectionStore()
        typed.apply(key: ProjectionKey.title, value: .string("Fix the flaky check"), seq: 1)
        typed.apply(key: ProjectionKey.modelSelection, value: json(#"{"lastUsed":{"provider":"deepseek","model":"a"},"next":{"provider":"deepseek","model":"b","reasoningEffort":"high"}}"#), seq: 1)
        typed.apply(key: ProjectionKey.imageLimits, value: json(#"{"maxImageBytes":1048576,"maxImagesPerMessage":2}"#), seq: 1)
        typed.apply(key: ProjectionKey.permissions, value: json(#"{"options":[{"value":"ask","name":"Ask","description":"Prompt each time"},{"value":"custom","name":"Custom"}],"currentValue":"custom"}"#), seq: 1)
        typed.apply(key: ProjectionKey.plan, value: json(#"{"active":true,"pending":false}"#), seq: 1)
        typed.apply(key: ProjectionKey.goal, value: json(#"{"goal":{"id":"g1","revision":2,"objective":"Ship C1","phase":"blocked","blockedReason":{"code":"needs-review","message":"Waiting on review"},"maxGoalRounds":4},"roundsStarted":2,"createdAt":1,"updatedAt":2}"#), seq: 1)
        typed.apply(key: ProjectionKey.todos, value: json(#"[{"content":"Write the store","status":"completed"},{"content":"Wire PocketStore","status":"in_progress"}]"#), seq: 1)
        typed.apply(key: ProjectionKey.sessionStats, value: json(#"{"turns":3,"steps":8,"llmMs":1200,"toolMs":340,"ttftMs":90,"ttftSteps":3,"decodeMs":500,"decodeTokens":240}"#), seq: 1)
        typed.apply(key: ProjectionKey.tokenUsage, value: json(#"{"uncachedInputTokens":1200,"outputTokens":340,"cacheReadTokens":8000,"cacheWriteTokens":500}"#), seq: 1)
        typed.apply(key: ProjectionKey.contextBreakdown, value: json(#"{"systemTokens":900,"toolsTokens":2100,"messageTokens":6400}"#), seq: 1)
        typed.apply(key: ProjectionKey.contextPressure, value: json(#"{"pressureTokens":24000,"projectedTokens":25500,"contextWindow":128000}"#), seq: 1)
        typed.apply(key: ProjectionKey.turnOutline, value: json(#"[{"turn":1,"seq":4,"prompt":"Do the thing","response":"Done"},{"turn":2,"seq":19,"prompt":"Again","response":""}]"#), seq: 1)
        typed.apply(key: ProjectionKey.schedule, value: json(#"[{"id":"s1","state":"scheduled"}]"#), seq: 1)
        typed.apply(key: ProjectionKey.agentPreset, value: .string("default"), seq: 1)
        typed.apply(key: ProjectionKey.inbox, value: json(#"{"next-turn":[{"type":"text"}],"next-step":[]}"#), seq: 1)
        typed.apply(key: ProjectionKey.sessionListMetadata, value: json(#"{"blank":false,"lastPromptAt":1741000000000}"#), seq: 1)
        assert(typed.title?.text == "Fix the flaky check")
        assert(typed.modelSelection?.provider == "deepseek" && typed.modelSelection?.model == "b" && typed.modelSelection?.effort == "high")
        assert(typed.modelSelection?.next["model"].string == "b", "The raw selection is preserved for request assembly")
        assert(typed.imageLimits?.maxBytes == 1048576 && typed.imageLimits?.maxCount == 2)
        assert(typed.permissions?.currentValue == "custom" && typed.permissions?.options.count == 2 && typed.permissions?.options[0].name == "Ask")
        assert(typed.plan?.active == true && typed.plan?.pending == false)
        assert(typed.goal?.objective == "Ship C1" && typed.goal?.phase == "blocked" && typed.goal?.roundsStarted == 2 && typed.goal?.maxGoalRounds == 4)
        assert(typed.goal?.blockedReason == "Waiting on review")
        assert(typed.todos?.count == 2 && typed.todos?[1].status == "in_progress" && typed.todos?[0].content == "Write the store")
        assert(typed.sessionStats?.turns == 3 && typed.sessionStats?.steps == 8 && typed.sessionStats?.llmMs == 1200 && typed.sessionStats?.toolMs == 340)
        assert(typed.tokenUsage?.uncachedInputTokens == 1200 && typed.tokenUsage?.outputTokens == 340 && typed.tokenUsage?.cacheReadTokens == 8000 && typed.tokenUsage?.cacheWriteTokens == 500)
        assert(typed.contextBreakdown?.systemTokens == 900 && typed.contextBreakdown?.toolsTokens == 2100 && typed.contextBreakdown?.messageTokens == 6400)
        assert(typed.contextPressure?.percent == 24000.0 / 128000.0 && typed.contextPressure?.used == 24000 && typed.contextPressure?.limit == 128000)
        assert(typed.contextPressure?.hasWindow == true && typed.contextPressure?.projectedTokens == 25500)
        assert(typed.turnOutline?.turns.count == 2 && typed.turnOutline?.turns[0].prompt == "Do the thing" && typed.turnOutline?.turns[1].seq == 19)
        assert(typed.schedule?.count == 1)
        assert(typed.agentPreset?.name == "default" && typed.agentPreset?.present == true)
        assert(typed.inbox?.nextTurn == 1 && typed.inbox?.nextStep == 0)
        assert(typed.sessionListMetadata?.blank == false && typed.sessionListMetadata?.lastPromptAt == 1741000000000)
        // Hostile or older payloads: wrong types and missing fields degrade.
        // A value that arrived but is not an object at all (null, a number, a
        // list) is not a goal: absent, not a decoded default.
        for nonObject in ["null", "0", "\"text\"", "[]"] {
            assert(GoalProjection(json(nonObject)).present == false, "\(nonObject) must not read as a goal")
        }
        for degradedKey in [ProjectionKey.title, ProjectionKey.goal, ProjectionKey.todos, ProjectionKey.inbox, ProjectionKey.contextPressure] {
            var degraded = SessionProjectionStore()
            degraded.apply(key: degradedKey, value: json(#"{"nextTurn":"many"}"#), seq: 1)
            switch degradedKey {
            case ProjectionKey.title: assert(degraded.title?.text == "")
            case ProjectionKey.goal: assert(degraded.goal?.present == true && degraded.goal?.objective == "" && degraded.goal?.roundsStarted == 0)
            case ProjectionKey.todos: assert(degraded.todos?.isEmpty == true)
            case ProjectionKey.inbox: assert(degraded.inbox?.nextTurn == 0 && degraded.inbox?.nextStep == 0)
            default: assert(degraded.contextPressure?.percent == 0 && degraded.contextPressure?.hasPressure == false)
            }
        }
        assert(SessionTitle(.null).text == "" && SessionTitle(json(#"{"title":"wrapped"}"#)).text == "wrapped")
        assert(GoalProjection(.null).present == false && GoalProjection(.null).objective == "")
        assert(ModelSelectionProjection(.null).hasSelection == false)
        print("PASS: modelled keys decode realistic fixtures and degrade safely on malformed values")

        // The read path HarnessSession.title uses: a plain string title, and the
        // projector's own patch path, both resolve through the same lookup.
        let sid = "session-1"
        var raw = json(#"{"sessionId":"session-1","projections":{"values":{"title":"Projected title"}}}"#)
        assert(HarnessSession(raw: raw).title == "Projected title")
        var projection = SessionProjectionStore()
        projection.apply(key: ProjectionKey.title, value: .string("Patched title"), seq: 9)
        patch(raw: &raw, from: projection)
        assert(HarnessSession(raw: raw).title == "Patched title", "The patched container must keep HarnessSession.title working")
        var cleared = raw.object
        projection.reset()
        cleared["projections"] = .object(["values": .object([:])])
        let emptied = JSON.object(cleared)
        assert(HarnessSession(raw: emptied).title == "New task", "An absent title falls back to the placeholder")
        assert(raw["projections"]["values"]["title"].string == "Patched title" && sid.isEmpty == false)
        print("PASS: title resolves through the HarnessSession.title container")

        // Two sessions keep independent seq bookkeeping, as the host streams them.
        var a = SessionProjectionStore(), b = SessionProjectionStore()
        a.apply(key: ProjectionKey.title, value: .string("A"), seq: 3)
        b.apply(key: ProjectionKey.title, value: .string("B"), seq: 1)
        assert(a.title?.text == "A" && b.title?.text == "B")
        print("PASS: per-session stores keep independent watermarks")
    }

    /// Mirrors PocketStore.patchProjection's container write: the store's value
    /// is what lands in `raw["projections"]["values"]`.
    static func patch(raw: inout JSON, from store: SessionProjectionStore) {
        var object = raw.object, container = object["projections"]?.object ?? [:], values = container["values"]?.object ?? [:]
        for (key, row) in store.rows { values[key] = row.value }
        container["values"] = .object(values); object["projections"] = .object(container); raw = .object(object)
    }
}
