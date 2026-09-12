import Foundation

/// One catalog pull's failure, as the app reports it: a message the warmup
/// error renders verbatim.
struct PullError: Error, Equatable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main struct CommandCatalogChecks {
    static func json(_ s: String) -> JSON { try! JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }
    static func descriptor(_ name: String) -> CommandDescriptor {
        CommandDescriptor(json(#"{"name":"\#(name)","description":"d"}"#))
    }
    static func parse(_ line: String) -> (name: String, rawInput: String) {
        let result = parseCommand(line)!
        return (result.name, result.rawInput)
    }
    /// Wait until the background wait reaches the expected state. The condition
    /// is polled with a short sleep up to a generous deadline: a fixed number of
    /// yields is not a wait, and under a sanitizer - or a slow machine - it is
    /// not enough for the awaiting task to register its waiter.
    @MainActor
    static func spin(_ reached: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if reached() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        assert(reached(), "the background wait never reached the expected state")
    }
    /// The directory is `@MainActor` by construction; driving the checks on the
    /// main actor is what makes the wait/join interleavings deterministic
    /// instead of a race between the test body and the awaited pull.
    @MainActor
    static func main() async throws {
        // Descriptors: input absent, present with attachments true/false,
        // and attachments absent inside a present input.
        let full = CommandDescriptor(json(#"{"name":"compact","description":"Compact the session","input":{"hint":"compact [reason]","attachments":true}}"#))
        assert(full.name == "compact" && full.description == "Compact the session")
        assert(full.input?.hint == "compact [reason]" && full.input?.attachments == true)
        let bare = CommandDescriptor(json(#"{"name":"goal","description":"Manage the goal"}"#))
        assert(bare.input == nil, "an absent input stays absent")
        let off = CommandDescriptor(json(#"{"name":"x","description":"d","input":{"hint":"h","attachments":false}}"#))
        assert(off.input?.attachments == false, "an explicit false is kept")
        let absent = CommandDescriptor(json(#"{"name":"y","description":"d","input":{"hint":"h"}}"#))
        assert(absent.input != nil && absent.input?.attachments == nil, "an absent attachments flag stays absent")
        print("PASS: command descriptor decoding")

        // Results: success with/without text and sourceEventSeq, error.
        let rich = CommandResult(json(#"{"kind":"success","text":"done","sourceEventSeq":42}"#))
        assert(rich.isSuccess && !rich.isError && rich.text == "done" && rich.sourceEventSeq == 42)
        let bareResult = CommandResult(json(#"{"kind":"success"}"#))
        assert(bareResult.isSuccess && bareResult.text == nil && bareResult.sourceEventSeq == nil, "text and sourceEventSeq are optional")
        let failure = CommandResult(json(#"{"kind":"error","text":"boom"}"#))
        assert(failure.isError && failure.text == "boom" && failure.sourceEventSeq == nil)
        print("PASS: command result decoding")

        // Executions and attachments (image and file).
        let execution = CommandExecution(json(#"{"commandId":"c1","result":{"kind":"error","text":"no"}}"#))
        assert(execution.commandId == "c1" && execution.result.isError && execution.result.text == "no")
        let image = CommandSubmitAttachment(json(#"{"type":"image","mediaType":"image/png","data":"aGVsbG8=","name":"shot.png"}"#))
        assert(image.type == "image" && image.mediaType == "image/png" && image.data == "aGVsbG8=" && image.name == "shot.png" && !image.isFile)
        let file = CommandSubmitAttachment(json(#"{"type":"file","receiptId":"r7"}"#))
        assert(file.isFile && file.receiptId == "r7" && file.name == nil)
        print("PASS: command execution and attachment decoding")

        // command/run and command/done event payloads; args absent.
        let run = CommandRunEvent(json(#"{"commandId":"c1","name":"compact","source":{"kind":"user"}}"#))
        assert(run.commandId == "c1" && run.name == "compact" && run.sourceKind == "user" && run.args == nil, "args absent when recordInput is false")
        let runWithArgs = CommandRunEvent(json(#"{"commandId":"c2","name":"goal","args":"set x","source":{"kind":"user"}}"#))
        assert(runWithArgs.args == "set x")
        let done = CommandDoneEvent(json(#"{"commandId":"c1","kind":"success","sourceEventSeq":7}"#))
        assert(done.commandId == "c1" && done.kind == "success" && done.text == nil && done.sourceEventSeq == 7)
        let doneError = CommandDoneEvent(json(#"{"commandId":"c2","kind":"error","text":"no such command"}"#))
        assert(doneError.kind == "error" && doneError.text == "no such command" && doneError.sourceEventSeq == nil)
        print("PASS: command/run and command/done event decoding")

        // parseCommand hits: the separator stays OUT of the match, so
        // rawInput keeps it (the lookahead is zero-width).
        assert(parse("/compact") == ("compact", ""), "bare command")
        assert(parse("/compact now") == ("compact", " now"), "the space stays in rawInput")
        assert(parse("/compact\t--flag") == ("compact", "\t--flag"), "a tab is a separator")
        assert(parse("/compact-2 x") == ("compact-2", " x"))
        assert(parse("/compact ").rawInput == " ", "a trailing space stays")
        assert(parse("/a") == ("a", ""), "a single-letter name")
        // Misses: no leading "/", no trim inside (host-faithful), uppercase,
        // leading digit, a comma that is neither a name part nor a separator,
        // an empty or bare "/", and a dot: not in [a-z0-9_-] and not a
        // separator, so the lookahead fails exactly like the comma case.
        for line in ["compact", "/Compact", "//compact", "/1compact", "/compact,extra", "", "/", " /compact", "/a-b_c.d"] {
            assert(parseCommand(line) == nil, "miss: \(line)")
        }
        print("PASS: parseCommand hits and misses")

        // submittedCommandName: trim, first token, strip the leading "/".
        assert(submittedCommandName("/compact") == "compact")
        assert(submittedCommandName("  /compact now  ") == "compact")
        assert(submittedCommandName("compact") == "compact", "no slash to strip")
        assert(submittedCommandName("/compact extra args") == "compact")
        print("PASS: submittedCommandName")

        // cold -> refresh -> ready; a ready snapshot resolves by name.
        var pulls = 0
        let directory = CommandDirectory { _ in
            pulls += 1
            return [descriptor("compact"), descriptor("goal")]
        }
        assert(directory.status("s1") == .cold && directory.entries["s1"] == nil, "never touched is cold")
        directory.refresh("s1")
        assert(directory.status("s1") == .ready && pulls == 1)
        assert(directory.resolve("s1", "goal")?.description == "d")
        assert(directory.resolve("s1", "missing") == nil)
        assert(directory.entries["s1"]!.epoch == 1, "the first pull is epoch 1 of generation 0")

        // Epoch guard: a second pull started while the first is in flight
        // bumps the epoch; the stale first outcome is discarded, the latest wins.
        var fetchCall = 0
        var guardRef: CommandDirectory!
        let guarded = CommandDirectory { id in
            fetchCall += 1
            if fetchCall == 1 {
                guardRef.refresh(id)  // the second pull starts inside the first fetch
                return [descriptor("old")]
            }
            return [descriptor("new")]
        }
        guardRef = guarded
        guarded.refresh("s1")
        assert(fetchCall == 2)
        assert(guarded.status("s1") == .ready && guarded.entries["s1"]!.epoch == 2)
        assert(guarded.resolve("s1", "new") != nil && guarded.resolve("s1", "old") == nil, "the stale outcome is discarded, the latest wins")
        print("PASS: directory cold refresh and epoch guard")

        // Fetch failure: failed + lastError. A ready entry whose soft
        // repull fails also becomes failed - the reference semantics, kept
        // exactly (the ready state is only protected while the pull flies).
        var failures = 0
        let failing = CommandDirectory { _ in
            failures += 1
            guard failures == 1 else { throw PullError(message: "command.list failed: net: down") }
            return [descriptor("ok")]
        }
        failing.refresh("s1")
        assert(failing.status("s1") == .ready)
        failing.refresh("s1")
        assert(failing.status("s1") == .failed, "a failed repull demotes the ready entry")
        assert(failing.entries["s1"]!.commands.isEmpty)
        assert((failing.entries["s1"]!.lastError as? PullError)?.message == "command.list failed: net: down")
        assert(failing.resolve("s1", "ok") == nil, "a failed entry serves nothing")
        let coldFail = CommandDirectory { _ in throw PullError(message: "boom") }
        coldFail.refresh("s2")
        assert(coldFail.status("s2") == .failed)
        print("PASS: directory failure and lastError")

        // resetSession: clear the entry, then repull the replacement.
        var version = 0
        let resetting = CommandDirectory { _ in
            version += 1
            return [descriptor("v\(version)")]
        }
        resetting.refresh("s1")
        assert(resetting.resolve("s1", "v1") != nil)
        resetting.resetSession("s1")
        assert(resetting.status("s1") == .ready)
        assert(resetting.resolve("s1", "v2") != nil && resetting.resolve("s1", "v1") == nil, "the reset repulls")
        resetting.resetSession("s2")
        assert(resetting.resolve("s2", "v3") != nil, "an untouched session is admitted and pulled")
        print("PASS: directory resetSession")

        // warm: pulls from cold, skips ready, repulls failed.
        var warmPulls = 0
        let warming = CommandDirectory { _ in
            warmPulls += 1
            return [descriptor("w")]
        }
        warming.warm("s1")
        assert(warmPulls == 1 && warming.status("s1") == .ready, "warm pulls from cold")
        warming.warm("s1")
        assert(warmPulls == 1, "warm skips a ready entry")
        var warmFail = 0
        let warmFailing = CommandDirectory { _ in
            warmFail += 1
            guard warmFail == 1 else { return [descriptor("w")] }
            throw PullError(message: "down")
        }
        warmFailing.warm("s1")
        assert(warmFailing.status("s1") == .failed && warmFail == 1)
        warmFailing.warm("s1")
        assert(warmFail == 2 && warmFailing.status("s1") == .ready, "warm repulls a failed entry")
        print("PASS: directory warm")

        // invalidateAll: a background repull on every key; the ready
        // snapshot keeps serving while the pull flies.
        var softPulls = 0
        var softRef: CommandDirectory!
        let softening = CommandDirectory { id in
            softPulls += 1
            if softPulls == 2 {
                assert(softRef.resolve(id, "old") != nil, "the ready snapshot serves during the repull")
            }
            return softPulls == 1 ? [descriptor("old")] : [descriptor("new")]
        }
        softRef = softening
        softening.refresh("s1")
        assert(softening.status("s1") == .ready && softPulls == 1)
        softening.invalidateAll()
        assert(softPulls == 2 && softening.status("s1") == .ready)
        assert(softening.resolve("s1", "new") != nil && softening.resolve("s1", "old") == nil)
        print("PASS: directory invalidateAll keeps the ready snapshot serving")

        // resetConnected: every entry drops its snapshot and prewarms.
        let hardReset = CommandDirectory { id in [descriptor("re-\(id)")] }
        hardReset.refresh("a")
        hardReset.refresh("b")
        hardReset.resetConnected()
        assert(hardReset.status("a") == .ready && hardReset.status("b") == .ready)
        assert(hardReset.resolve("a", "re-a") != nil && hardReset.resolve("b", "re-b") != nil, "every entry repulls after the hard reset")
        print("PASS: directory resetConnected")

        // ensureReady: cold pulls, ready returns at once, a failed warmup
        // throws the command directory warmup failed message.
        var erPulls = 0
        let ensuring = CommandDirectory { _ in
            erPulls += 1
            return [descriptor("e")]
        }
        let warmup = try ensuring.ensureReady("s1")
        assert(erPulls == 1 && warmup == [descriptor("e")])
        let cached = try ensuring.ensureReady("s1")
        assert(erPulls == 1 && cached == [descriptor("e")], "a ready entry returns at once")
        var erFails = 0
        let failingEnsure = CommandDirectory { _ in
            erFails += 1
            guard erFails == 1 else { return [descriptor("e")] }
            throw PullError(message: "down")
        }
        do {
            _ = try failingEnsure.ensureReady("s1")
            assert(false, "a failed warmup must throw")
        } catch let failure as CommandDirectory.WarmupFailure {
            assert(failure.reason.hasPrefix("command directory warmup failed:"))
            assert(erFails == 1)
        } catch {
            assert(false, "unexpected error: \(error)")
        }
        // Waiters wake exactly once, on the next winning publish.
        var woken = 0
        let waiting = CommandDirectory { _ in [descriptor("w")] }
        waiting.settle("s1") { cancelled in assert(!cancelled, "a publish is not a cancellation"); woken += 1 }
        waiting.refresh("s1")
        assert(woken == 1, "a waiter wakes on the winning publish")
        waiting.settle("s1") { cancelled in assert(!cancelled, "a publish is not a cancellation"); woken += 1 }
        waiting.refresh("s1")
        assert(woken == 2, "each publish wakes the waiters registered for it")
        print("PASS: directory ensureReady and waiters")

        // Wire arguments: the exact keys the Host declares. commands/execute
        // takes submittedAttachments; there is no images parameter, and an
        // invocation that carries one is rejected.
        let listArgs = commandListArguments(agentId: "s1")
        assert(Set(listArgs.keys) == ["agentId"] && listArgs["agentId"] == .string("s1"), "commands/list is addressed by agentId")
        let executeArgs = commandExecuteArguments(agentId: "s1", line: "/goal set x", submittedAttachments: [])
        assert(Set(executeArgs.keys) == ["agentId", "line", "submittedAttachments"], "commands/execute carries no images parameter")
        assert(executeArgs["agentId"] == .string("s1") && executeArgs["line"] == .string("/goal set x"))
        assert(executeArgs["submittedAttachments"] == .array([]))
        let imageAttachment = CommandSubmitAttachment(json(#"{"type":"image","mediaType":"image/png","data":"aGk="}"#))
        let withImage = commandExecuteArguments(agentId: "s1", line: "/x", submittedAttachments: [imageAttachment.wire!])
        assert(withImage["submittedAttachments"]?.array.count == 1)
        assert(withImage["images"] == nil, "the removed parameter never reappears")
        assert(commandDescriptors(json(#"[{"name":"a","description":"d"},{"name":"b","description":"d"}]"#)).map(\.name) == ["a", "b"])
        assert(commandDescriptors(.null).isEmpty, "a non-array payload reads as an empty catalog")
        print("PASS: command wire arguments")

        // Submission attachment wire arms: an image carries its media type and
        // data (name only when present); a file must carry its receipt, and a
        // receipt-less file has no union arm, so it fails instead of sending "".
        let plainImage = CommandSubmitAttachment(json(#"{"type":"image","mediaType":"image/png","data":"aGk="}"#)).wire
        assert(plainImage == .object(["type": .string("image"), "mediaType": .string("image/png"), "data": .string("aGk=")]))
        let namedImage = CommandSubmitAttachment(json(#"{"type":"image","mediaType":"image/jpeg","data":"aGk=","name":"shot.jpg"}"#)).wire
        assert(namedImage?["name"] == .string("shot.jpg"))
        assert(CommandSubmitAttachment(json(#"{"type":"file","receiptId":"r7"}"#)).wire == .object(["type": .string("file"), "receiptId": .string("r7")]))
        assert(CommandSubmitAttachment(json(#"{"type":"file"}"#)).wire == nil, "a file without a receipt fails instead of sending an empty string")
        assert(CommandSubmitAttachment(json(#"{"type":"file","receiptId":""}"#)).wire == nil, "an empty receipt is not a union arm")
        print("PASS: submission attachment wire arms")

        // Attachment admission: only an explicit true admits attachments.
        assert(commandAdmitsAttachments(full) && !commandAdmitsAttachments(bare) && !commandAdmitsAttachments(off) && !commandAdmitsAttachments(absent))
        print("PASS: attachment admission")

        // Catalog origin: a subagent session short-circuits before the RPC.
        assert(commandCatalogRequest(sessionId: "s1", origin: "subagent") == .emptyCatalog)
        assert(commandCatalogRequest(sessionId: "s1", origin: "primary") == .list(agentId: "s1"), "the session id is the agent id")
        assert(commandCatalogRequest(sessionId: "s1", origin: "") == .list(agentId: "s1"))
        print("PASS: catalog origin decision")

        // The three wired invalidation events, against a directory whose
        // snapshot changes on every pull.
        var eventPull = 0
        let evented = CommandDirectory { _ in eventPull += 1; return [descriptor("v\(eventPull)")] }
        evented.refresh("a"); evented.refresh("b")
        assert(eventPull == 2)
        evented.apply(.commandsChanged)
        assert(eventPull == 4 && evented.status("a") == .ready && evented.status("b") == .ready, "commands/change repulls every touched key, ready snapshots keep serving")
        let afterSoftA = evented.entries["a"]!.commands.first?.name
        evented.apply(.agentPresetSelected(sessionId: "a"))
        assert(eventPull == 5, "agent-preset/selected refetches exactly one session")
        assert(evented.entries["a"]!.commands.first?.name != afterSoftA, "the reset session's snapshot is replaced")
        assert(evented.status("b") == .ready, "the other session is untouched")
        evented.apply(.connectionReset)
        assert(eventPull == 7 && evented.status("a") == .ready && evented.status("b") == .ready, "connection/reset prewarms every entry")
        print("PASS: catalog invalidation events")

        // The async seam: the directory mints the pull token and the caller
        // publishes under it. A stale outcome is dropped, the latest pull wins,
        // and the waiters wake only on the winning publish.
        var starts: [CommandDirectory.CommandPullToken] = []
        let asyncDirectory = CommandDirectory(startPull: { token in starts.append(token) })
        assert(asyncDirectory.status("s1") == .cold && starts.isEmpty, "no pull until something asks for one")
        asyncDirectory.refresh("s1")
        assert(starts.count == 1 && starts[0].sessionId == "s1" && starts[0].epoch == 1 && starts[0].catalogGeneration == 0)
        assert(asyncDirectory.status("s1") == .pending && asyncDirectory.resolve("s1", "x") == nil, "a pull in flight serves nothing")
        var wokenOnce = 0
        asyncDirectory.settle("s1") { cancelled in assert(!cancelled, "a publish wakes a waiter as published"); wokenOnce += 1 }
        let foreign = CommandDirectory.CommandPullToken(sessionId: "s1", epoch: 99, catalogGeneration: 0)
        asyncDirectory.publish(foreign, .success([descriptor("stale")]))
        assert(asyncDirectory.status("s1") == .pending && asyncDirectory.resolve("s1", "stale") == nil, "an outcome under a foreign epoch is dropped")
        assert(wokenOnce == 0, "a dropped publish wakes nobody")
        asyncDirectory.refresh("s1")
        assert(starts.count == 2 && starts[1].epoch == 2, "a second pull bumps the epoch")
        asyncDirectory.publish(starts[0], .success([descriptor("old")]))
        assert(asyncDirectory.resolve("s1", "old") == nil, "the superseded pull's outcome never lands")
        asyncDirectory.publish(starts[1], .success([descriptor("new")]))
        assert(asyncDirectory.status("s1") == .ready && asyncDirectory.resolve("s1", "new") != nil && wokenOnce == 1)
        asyncDirectory.refresh("s1")
        assert(starts.count == 3 && asyncDirectory.status("s1") == .ready, "a repull keeps the ready snapshot serving")
        asyncDirectory.publish(starts[1], .failure(PullError(message: "late")))
        assert(asyncDirectory.status("s1") == .ready && asyncDirectory.resolve("s1", "new") != nil, "the superseded token cannot demote the entry")
        asyncDirectory.publish(starts[2], .failure(PullError(message: "down")))
        assert(asyncDirectory.status("s1") == .failed && (asyncDirectory.entries["s1"]!.lastError as? PullError)?.message == "down", "the latest pull publishes its failure")
        asyncDirectory.warm("s1")
        assert(starts.count == 4, "warm repulls a failed entry")
        asyncDirectory.removeAll()
        assert(asyncDirectory.status("s1") == .cold && starts.count == 4, "removeAll drops every snapshot without pulling")
        assert(asyncDirectory.catalogGeneration == 1, "removeAll opens a new catalog generation")
        print("PASS: async pull token guard and removeAll")

        // The durable lifecycle fold: run opens a record, done settles it in
        // place, duplicates are idempotent, a re-delivered run never reopens a
        // settled command, and a done whose run is outside the window renders.
        var fold = CommandLifecycleFold()
        assert(fold.apply(json(#"{"type":"assistant/chunk","seq":1,"data":{}}"#)) == nil, "a non-lifecycle frame changes nothing")
        assert(fold.apply(json(#"{"type":"command/run","seq":2,"data":{"commandId":"c1","name":"goal","args":" set x"}}"#)) == 0)
        assert(fold.records.count == 1 && fold.record("c1")?.invocation == "/goal set x")
        assert(fold.record("c1")?.settled == false && commandRow(fold.record("c1")!).complete == false, "an unsettled command reads running")
        assert(fold.apply(json(#"{"type":"command/done","seq":3,"data":{"commandId":"c1","kind":"success","text":"goal set","sourceEventSeq":2}}"#)) == 0)
        assert(fold.records.count == 1 && fold.record("c1")?.outcome?.sourceEventSeq == 2)
        assert(commandRow(fold.record("c1")!).complete && commandRow(fold.record("c1")!).failed == false)
        assert(fold.apply(json(#"{"type":"command/done","seq":4,"data":{"commandId":"c1","kind":"success","text":"goal set"}}"#)) == 0 && fold.records.count == 1, "a duplicate done lands on the same record")
        assert(fold.apply(json(#"{"type":"command/run","seq":5,"data":{"commandId":"c1","name":"other"}}"#)) == 0)
        assert(fold.record("c1")?.name == "goal" && fold.record("c1")?.outcome != nil, "a re-delivered run never reopens a settled command")
        assert(fold.apply(json(#"{"type":"command/done","seq":6,"data":{"commandId":"c2","kind":"error","text":"no such command"}}"#)) == 1)
        assert(fold.record("c2")?.name == nil && fold.record("c2")?.outcome?.isError == true)
        assert(commandRow(fold.record("c2")!).failed && commandRow(fold.record("c2")!).complete, "a done without its run still renders as failed")
        assert(fold.apply(json(#"{"type":"command/run","seq":7,"data":{"commandId":"","name":"x"}}"#)) == nil, "an empty commandId is not a record")
        _ = fold.apply(json(#"{"type":"command/done","seq":8,"data":{"commandId":"c3","kind":"error","text":"boom","sourceEventSeq":9}}"#))
        assert(fold.record("c3")?.outcome?.sourceEventSeq == nil, "an error's sourceEventSeq is meaningless")
        _ = fold.apply(json(#"{"type":"command/done","seq":9,"data":{"commandId":"c4","kind":"success","sourceEventSeq":-1}}"#))
        assert(fold.record("c4")?.outcome?.sourceEventSeq == nil, "a negative seq cannot point at an earlier event")
        print("PASS: command lifecycle fold")

        // The $events emit mapping the store wires to the directory
        // (dsh-client-ui-commands client.js:537-545).
        assert(commandCatalogEvent(name: "commands/change", args: []) == .commandsChanged)
        assert(commandCatalogEvent(name: "commands/change", args: [.string("ignored")]) == .commandsChanged, "commands/change carries no args")
        assert(commandCatalogEvent(name: "agent-preset/selected", args: [.string("s1"), .string("preset")]) == .agentPresetSelected(sessionId: "s1"))
        assert(commandCatalogEvent(name: "agent-preset/selected", args: [.string("s1")]) == nil, "a malformed preset emit changes nothing")
        assert(commandCatalogEvent(name: "api-session/status", args: [.string("s1")]) == nil, "an unrelated emit changes nothing")
        print("PASS: emit frame to catalog event mapping")

        // The matchEnter claim decision once the catalog is servable: an input
        // command claims the line as typed, a no-input command only its bare
        // token, and an unknown name is never claimed (client.js:735, 747-752).
        assert(commandClaimsLine("/compact now", descriptor: full), "an input command claims the line as typed")
        assert(commandClaimsLine("/compact", descriptor: full))
        assert(commandClaimsLine("/goal", descriptor: bare), "a no-input command claims its bare token")
        assert(!commandClaimsLine("/goal clear", descriptor: bare), "trailing arguments on a no-input command are not claimed")
        assert(!commandClaimsLine("/goal clear", descriptor: nil), "an unknown name is not claimed")
        print("PASS: the matchEnter claim decision")

        // The asynchronous strong wait (JS ensureReady, client.js:118-126): a
        // cold entry starts the pull it needs and a pending entry joins the
        // pull in flight; both return the winning snapshot.
        var waitStarts: [CommandDirectory.CommandPullToken] = []
        let waited = CommandDirectory(startPull: { token in waitStarts.append(token) })
        let cold = Task { try await waited.ensureReadyAsync("s1") }
        await spin { !waitStarts.isEmpty }
        assert(waitStarts.count == 1 && waitStarts[0].sessionId == "s1" && waited.status("s1") == .pending, "the wait starts the pull it needs")
        let joined = Task { try await waited.ensureReadyAsync("s1") }
        await spin { (waited.entries["s1"]?.waiters.count ?? 0) == 2 }
        assert(waitStarts.count == 1, "a pending entry joins the pull in flight")
        waited.publish(waitStarts[0], .success([descriptor("goal")]))
        let coldResult = try await cold.value
        let joinedResult = try await joined.value
        assert(coldResult == [descriptor("goal")] && joinedResult == [descriptor("goal")])
        assert(waited.status("s1") == .ready)
        print("PASS: the strong wait serves a cold entry and joins a pending pull")

        // A failed pull rejects the wait (the reference's "never a silent
        // downgrade") and does not poison the key: the next wait repulls.
        var failWaitStarts: [CommandDirectory.CommandPullToken] = []
        let failingWait = CommandDirectory(startPull: { token in failWaitStarts.append(token) })
        let rejected = Task { try await failingWait.ensureReadyAsync("s1") }
        await spin { !failWaitStarts.isEmpty }
        failingWait.publish(failWaitStarts[0], .failure(PullError(message: "down")))
        do {
            _ = try await rejected.value
            assert(false, "a failed warmup must reject the wait")
        } catch let failure as CommandDirectory.WarmupFailure {
            assert(failure.reason == "command directory warmup failed: down")
        } catch { assert(false, "unexpected error: \(error)") }
        assert(failingWait.status("s1") == .failed)
        let retried = Task { try await failingWait.ensureReadyAsync("s1") }
        await spin { failWaitStarts.count == 2 }
        assert(failingWait.status("s1") == .pending, "the retry repulls a failed entry")
        failingWait.publish(failWaitStarts[1], .success([descriptor("recovered")]))
        let retriedResult = try await retried.value
        assert(retriedResult == [descriptor("recovered")])
        print("PASS: a failed warmup rejects and the next wait repulls")

        // The regression group this port needed: a pull identity that survives
        // a clear. Before the catalog generation, an outcome minted before
        // removeAll collided with the next connection's pull, whose epoch
        // restarted at 1 for the same session key - a late success could land,
        // and a late abandon could fail a healthy catalog.
        try await catalogIdentityChecks()
        print("PASS: catalog pull identity across clears")

        // The store's connection-scoped pull bookkeeping, which lives in
        // CommandCatalog.swift so this gate can compile and drive it.
        await commandPullConnectionChecks()
    }

    /// The cross-connection regression group. Each check drives the exact
    /// ordering a reconnect produces - a pull of the old connection still in
    /// flight while the map is cleared and the next connection pulls for the
    /// same session key - and asserts that the old outcome changes nothing.
    /// A check that fails here is the DSH-REVIEW-1 symptom: a healthy new
    /// catalog demoted to failed and left empty, or a dead connection's stale
    /// snapshot served to the new connection's waiters.
    @MainActor
    static func catalogIdentityChecks() async throws {
        // Both response orders of a reconnect where the sessionId is reused.
        // The old pull's success arrives first: it must not land on the new
        // connection's pending pull (probe G: before the generation it did,
        // and the new connection served the dead snapshot).
        var oldFirstStarts: [CommandDirectory.CommandPullToken] = []
        let oldFirst = CommandDirectory(startPull: { token in oldFirstStarts.append(token) })
        oldFirst.refresh("s1")
        let oldFirstPull = oldFirstStarts[0]
        oldFirst.removeAll()
        oldFirst.refresh("s1")
        let newFirstPull = oldFirstStarts[1]
        assert(oldFirstPull.sessionId == newFirstPull.sessionId && oldFirstPull.epoch == newFirstPull.epoch,
               "a reconnect reuses the session key and restarts the epoch")
        assert(oldFirstPull.catalogGeneration != newFirstPull.catalogGeneration,
               "the cleared connection and its replacement are different identities")
        oldFirst.publish(oldFirstPull, .success([descriptor("dead")]))
        assert(oldFirst.status("s1") == .pending && oldFirst.resolve("s1", "dead") == nil,
               "a late success of the old connection cannot land on the new one")
        oldFirst.publish(newFirstPull, .success([descriptor("fresh")]))
        assert(oldFirst.status("s1") == .ready && oldFirst.resolve("s1", "fresh") != nil && oldFirst.resolve("s1", "dead") == nil,
               "the new connection's own pull still wins inside its generation")
        print("PASS: a late success of the old connection never lands on the new one")

        // The old pull's failure arrives after the new connection is ready
        // (the ticket's order A/F): it must not demote the healthy catalog.
        var lateFailureStarts: [CommandDirectory.CommandPullToken] = []
        let lateFailure = CommandDirectory(startPull: { token in lateFailureStarts.append(token) })
        lateFailure.refresh("s1")
        let deadPull = lateFailureStarts[0]
        lateFailure.removeAll()
        lateFailure.refresh("s1")
        lateFailure.publish(lateFailureStarts[1], .success([descriptor("fresh")]))
        assert(lateFailure.status("s1") == .ready)
        lateFailure.publish(deadPull, .failure(PullError(message: "the connection was reset before the command catalog arrived")))
        assert(lateFailure.status("s1") == .ready && lateFailure.resolve("s1", "fresh") != nil,
               "a late failure of the old connection cannot demote the new one")
        print("PASS: a late failure of the old connection never demotes the new one")

        // The store's generation guard turns a late success into an abandon;
        // an abandon must be shielded exactly like a publish. This is the
        // ticket's reproduction: old pull epoch 1 -> removeAll -> new pull of
        // the same session epoch 1 -> new success -> the old abandon demoted
        // the ready catalog to failed and emptied it.
        var abandonStarts: [CommandDirectory.CommandPullToken] = []
        let abandoned = CommandDirectory(startPull: { token in abandonStarts.append(token) })
        abandoned.refresh("s1")
        let abandonedPull = abandonStarts[0]
        abandoned.removeAll()
        abandoned.refresh("s1")
        abandoned.publish(abandonStarts[1], .success([descriptor("goal")]))
        assert(abandoned.status("s1") == .ready)
        abandoned.abandon(abandonedPull, reason: PullError(message: "the connection was reset before the command catalog arrived"))
        assert(abandoned.status("s1") == .ready && abandoned.resolve("s1", "goal") != nil,
               "a stale abandon cannot fail a newer generation's ready catalog")
        assert(abandoned.entries["s1"]!.commands.map(\.name) == ["goal"],
               "the demoted catalog would have been emptied")
        print("PASS: a stale abandon after a new success is dropped")

        // A waiter parked across the clear ends with the cancellation instead
        // of re-homing onto the next connection (probe D: before the token the
        // woken wait repulled for the same session key and was then rejected by
        // the dead connection's abandon).
        var cancelledStarts: [CommandDirectory.CommandPullToken] = []
        let cancelled = CommandDirectory(startPull: { token in cancelledStarts.append(token) })
        let orphan = Task { try await cancelled.ensureReadyAsync("s1") }
        await spin { cancelled.entries["s1"]?.waiters.count == 1 }
        assert(cancelledStarts.count == 1)
        cancelled.removeAll()
        do {
            _ = try await orphan.value
            assert(false, "a cleared wait must not resume")
        } catch let cancellation as CommandDirectory.CommandPullCancelled {
            assert(cancellation.reason == "the command catalog was dropped with its connection")
        } catch { assert(false, "unexpected error: \(error)") }
        assert(cancelledStarts.count == 1, "the cancelled wait must not start a pull for the next connection")
        assert(cancelled.status("s1") == .cold)
        print("PASS: a wait parked across the clear is cancelled, not re-homed")

        // The dead connection's outcome must not reject the next connection's
        // wait either. The old waiter ends cancelled, a fresh wait starts its
        // own pull, and only that pull's success serves it.
        var handoverStarts: [CommandDirectory.CommandPullToken] = []
        let handover = CommandDirectory(startPull: { token in handoverStarts.append(token) })
        let oldWait = Task { try await handover.ensureReadyAsync("s1") }
        await spin { handover.entries["s1"]?.waiters.count == 1 }
        let deadToken = handoverStarts[0]
        handover.removeAll()
        let newWait = Task { try await handover.ensureReadyAsync("s1") }
        await spin { handoverStarts.count == 2 && handover.entries["s1"]?.waiters.count == 1 }
        handover.abandon(deadToken, reason: PullError(message: "the connection was reset"))
        do {
            _ = try await oldWait.value
            assert(false, "the old wait must end cancelled")
        } catch is CommandDirectory.CommandPullCancelled {
        } catch { assert(false, "unexpected error: \(error)") }
        assert(handover.status("s1") == .pending, "the new wait is still parked on its own pull")
        assert(handover.entries["s1"]?.waiters.count == 1,
               "the dead connection's abandon must not wake the new connection's waiter")
        handover.publish(handoverStarts[1], .success([descriptor("goal")]))
        let served = try await newWait.value
        assert(served == [descriptor("goal")])
        print("PASS: the old wait ends cancelled and the dead connection's abandon wakes nobody")

        // A single resume: the one wait left after the handover ends exactly
        // once, on its own connection's publish, with the cancellation of the
        // clear already delivered to the other one.
        assert(handover.status("s1") == .ready)
        let resumed = Task { try await handover.ensureReadyAsync("s1") }
        let cachedResume = try await resumed.value
        assert(cachedResume == [descriptor("goal")] && handoverStarts.count == 2,
               "a ready catalog resumes a wait without another pull")
        let chained = try await handover.ensureReadyAsync("s1")
        assert(chained == [descriptor("goal")] && handoverStarts.count == 2)
        print("PASS: a single resume per wait")

        // The synchronous seam keeps its own contract: a ready entry records
        // the second pull as a newer identity, and the older token cannot
        // resolve it.
        var syncPulls = 0
        let sync = CommandDirectory { _ in
            syncPulls += 1
            return syncPulls == 1 ? [descriptor("old")] : [descriptor("new")]
        }
        let syncToken = sync.refresh("s1")
        assert(sync.status("s1") == .ready && sync.resolve("s1", "old") != nil)
        let newer = sync.refresh("s1")
        assert(sync.status("s1") == .ready && sync.resolve("s1", "new") != nil && sync.resolve("s1", "old") == nil,
               "the synchronous repull replaces the snapshot")
        assert(syncToken != newer, "a fresh pull mints a fresh identity")
        print("PASS: the synchronous repull mints a fresh identity")

        // A wait whose outcome was already published, and whose generation was
        // cleared in the same main-actor pass before the task could resume.
        // The publish removes the waiter and resumes the continuation; the
        // code after it runs before the resumed task does, so removeAll, the
        // next connection's pull and its publish all happen while that task is
        // still runnable. The old wait must end cancelled - before the
        // generation binding it resumed, re-read the map and served the new
        // connection's snapshot as its own answer.
        var raced: [CommandDirectory.CommandPullToken] = []
        let raceDirectory = CommandDirectory(startPull: { token in raced.append(token) })
        let racy = Task { () -> String in
            do {
                let result = try await raceDirectory.ensureReadyAsync("s1")
                return "SERVED " + (result.first?.name ?? "empty")
            } catch is CommandDirectory.CommandPullCancelled {
                return "CANCELLED"
            } catch {
                return "FAILED " + commandErrorMessage(error)
            }
        }
        await spin { raceDirectory.entries["s1"]?.waiters.count == 1 }
        assert(raced.count == 1)
        raceDirectory.publish(raced[0], .success([descriptor("old")]))
        raceDirectory.removeAll()
        let fresh = raceDirectory.refresh("s1")
        raceDirectory.publish(fresh, .success([descriptor("NEW CONNECTION")]))
        let racedOutcome = await racy.value
        assert(racedOutcome == "CANCELLED", "a wait cleared before its task resumed must end cancelled, got \(racedOutcome)")
        assert(raceDirectory.status("s1") == .ready && raceDirectory.resolve("s1", "NEW CONNECTION") != nil,
               "the new connection's own catalog is untouched by the old wait")
        print("PASS: a wait cleared before its task resumed ends cancelled")
    }

    /// A stand-in for the RPC one pull issues. It answers only when the gate
    /// is opened, which is what lets a check hold a pull inside its request.
    actor FakeCommandAPI {
        private(set) var calls = 0
        private(set) var parked = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []

        /// Every request parks until it is released: the checks decide when the
        /// transport answers, so a teardown can land before it, during it, or
        /// long after it.
        func rpc() async -> [CommandDescriptor] {
            calls += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parked += 1
                waiting.append(continuation)
            }
            return [descriptor("goal")]
        }

        func release() {
            let held = waiting
            waiting = []
            for continuation in held { continuation.resume() }
        }
    }

    /// The store's connection-scoped pull table: everything a pull does about
    /// its connection is decided here, on the main actor, before the transport
    /// is touched. Each case gets its own table and its own transport, so the
    /// request count of one case cannot be confused with another's.
    @MainActor
    static func commandPullConnectionChecks() async {
        let directory = CommandDirectory(startPull: { _ in })

        /// The pull body as the store writes it, with the transport replaced
        /// by a fake: the stale guards and the publish/abandon arms are the
        /// production ones.
        @MainActor func run(_ token: CommandDirectory.CommandPullToken,
                            _ connection: CommandPullConnection,
                            _ api: FakeCommandAPI) async {
            let attempt = directory.catalogGeneration
            func publish(_ outcome: Result<[CommandDescriptor], Error>) {
                if attempt == directory.catalogGeneration {
                    directory.publish(token, outcome)
                } else {
                    directory.abandon(token, reason: PullError(message: "the connection was reset"))
                }
            }
            guard !connection.isStale(token), !Task.isCancelled else { return }
            guard !connection.isStale(token), !Task.isCancelled else {
                publish(.failure(PullError(message: "the DSH connection is not ready")))
                return
            }
            let commands = await api.rpc()
            publish(.success(commands))
        }

        // 1. A normal pull: the table holds it before its body can run, one
        // request, ready, and the table is left clean.
        let normalConnection = CommandPullConnection(directory: directory)
        let normalAPI = FakeCommandAPI()
        directory.refresh("s1")
        let normal = directory.currentToken("s1")!
        normalConnection.bind(normal) { await run(normal, normalConnection, normalAPI) }
        assert(normalConnection.jobs[normal] != nil, "bind registers the pull before its task can run")
        while await normalAPI.parked == 0 { await Task.yield() }
        await normalAPI.release()
        await spin { directory.status("s1") == .ready && normalConnection.jobs.isEmpty }
        let normalCalls = await normalAPI.calls
        assert(normalCalls == 1 && directory.resolve("s1", "goal") != nil,
               "a normal pull issues one request, publishes and leaves the table")
        print("PASS: a normal pull publishes and leaves the connection table")

        // 2. The regression the reviewer reproduced: the pull's connection
        // dies before the body runs. The pull is in the table from bind time,
        // so stop() cancels that very task and removeAll() kills its identity;
        // when the body finally runs it must observe both and issue nothing.
        // The pre-fix store registered the pull one task hop late and captured
        // the connection identity inside the body, so this pull issued its
        // request against the next connection's transport.
        let lateConnection = CommandPullConnection(directory: directory)
        let lateAPI = FakeCommandAPI()
        directory.refresh("s2")
        let late = directory.currentToken("s2")!
        lateConnection.bind(late) {
            await Task.yield()                       // the pre-fix extra task hop
            guard !lateConnection.isStale(late), !Task.isCancelled else { return }
            _ = await lateAPI.rpc()
        }
        lateConnection.stop()
        directory.removeAll()
        await Task.yield()
        await Task.yield()
        let lateCalls = await lateAPI.calls
        assert(lateCalls == 0, "a pull whose connection died before its body ran issues no request")
        assert(directory.status("s2") == .cold, "the dead pull's outcome never lands")
        print("PASS: a pull whose connection died before its RPC is not issued")

        // 3. Disconnect while the RPC is in flight: the late outcome of the
        // dead connection must be dropped, it cannot land on the new pull.
        let flyingConnection = CommandPullConnection(directory: directory)
        let flyingAPI = FakeCommandAPI()
        directory.refresh("s3")
        let flying = directory.currentToken("s3")!
        flyingConnection.bind(flying) { await run(flying, flyingConnection, flyingAPI) }
        while await flyingAPI.parked == 0 { await Task.yield() }
        flyingConnection.stop()
        directory.removeAll()
        directory.refresh("s3")
        let replacement = directory.currentToken("s3")!
        assert(replacement != flying, "the new connection mints a different identity")
        await flyingAPI.release()                            // the dead RPC finally answers
        await Task.yield()
        await Task.yield()
        assert(directory.status("s3") == .pending,
               "the dead connection's late outcome is dropped, the new pull stays in flight")
        directory.publish(replacement, .success([descriptor("fresh")]))
        assert(directory.status("s3") == .ready && directory.resolve("s3", "fresh") != nil)
        assert(directory.resolve("s3", "goal") == nil, "the dead connection's snapshot never lands")
        print("PASS: a disconnect during the RPC drops the dead outcome")

        // 4. The wait of the dead connection ends cancelled and is not
        // re-homed: the new connection's pull serves only its own waiter.
        let parkedConnection = CommandPullConnection(directory: directory)
        let parkedAPI = FakeCommandAPI()
        directory.refresh("s4")
        let parked = directory.currentToken("s4")!
        parkedConnection.bind(parked) { await run(parked, parkedConnection, parkedAPI) }
        let oldWait = Task { try await directory.ensureReadyAsync("s4") }
        await spin { directory.entries["s4"]?.waiters.count == 1 }
        parkedConnection.stop()
        directory.removeAll()
        do {
            _ = try await oldWait.value
            assert(false, "the old wait must not resume with the new connection's data")
        } catch is CommandDirectory.CommandPullCancelled {
        } catch { assert(false, "unexpected error: \(error)") }
        let newWait = Task { try await directory.ensureReadyAsync("s4") }
        await spin { directory.entries["s4"]?.waiters.count == 1 }
        directory.publish(directory.currentToken("s4")!, .success([descriptor("fresh")]))
        let served = try? await newWait.value
        assert(served == [descriptor("fresh")], "the new connection's waiter is served its own snapshot")
        print("PASS: the dead connection's wait ends cancelled and only the new waiter is served")
    }
}
