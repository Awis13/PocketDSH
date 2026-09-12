import Foundation

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

        struct PullError: Error, Equatable, LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }

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
        assert(directory.entries["s1"]!.epoch == 1)

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
        waiting.settle("s1") { woken += 1 }
        waiting.refresh("s1")
        assert(woken == 1, "a waiter wakes on the winning publish")
        waiting.settle("s1") { woken += 1 }
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

        // The async seam: the directory mints the epoch and the caller
        // publishes. A stale outcome is dropped, the latest pull wins, and the
        // waiters wake only on the winning publish.
        var starts: [(String, Int)] = []
        let asyncDirectory = CommandDirectory(startPull: { id, epoch in starts.append((id, epoch)) })
        assert(asyncDirectory.status("s1") == .cold && starts.isEmpty, "no pull until something asks for one")
        asyncDirectory.refresh("s1")
        assert(starts.count == 1 && starts[0].0 == "s1" && starts[0].1 == 1)
        assert(asyncDirectory.status("s1") == .pending && asyncDirectory.resolve("s1", "x") == nil, "a pull in flight serves nothing")
        var wokenOnce = 0
        asyncDirectory.settle("s1") { wokenOnce += 1 }
        asyncDirectory.publish("s1", epoch: 99, .success([descriptor("stale")]))
        assert(asyncDirectory.status("s1") == .pending && asyncDirectory.resolve("s1", "stale") == nil, "an outcome under a foreign epoch is dropped")
        assert(wokenOnce == 0, "a dropped publish wakes nobody")
        asyncDirectory.refresh("s1")
        assert(starts.count == 2 && starts[1].1 == 2, "a second pull bumps the epoch")
        asyncDirectory.publish("s1", epoch: starts[0].1, .success([descriptor("old")]))
        assert(asyncDirectory.resolve("s1", "old") == nil, "the superseded pull's outcome never lands")
        asyncDirectory.publish("s1", epoch: starts[1].1, .success([descriptor("new")]))
        assert(asyncDirectory.status("s1") == .ready && asyncDirectory.resolve("s1", "new") != nil && wokenOnce == 1)
        asyncDirectory.refresh("s1")
        assert(starts.count == 3 && asyncDirectory.status("s1") == .ready, "a repull keeps the ready snapshot serving")
        asyncDirectory.publish("s1", epoch: starts[1].1, .failure(PullError(message: "late")))
        assert(asyncDirectory.status("s1") == .ready && asyncDirectory.resolve("s1", "new") != nil, "the superseded epoch cannot demote the entry")
        asyncDirectory.publish("s1", epoch: starts[2].1, .failure(PullError(message: "down")))
        assert(asyncDirectory.status("s1") == .failed && (asyncDirectory.entries["s1"]!.lastError as? PullError)?.message == "down", "the latest epoch publishes its failure")
        asyncDirectory.warm("s1")
        assert(starts.count == 4, "warm repulls a failed entry")
        asyncDirectory.removeAll()
        assert(asyncDirectory.status("s1") == .cold && starts.count == 4, "removeAll drops every snapshot without pulling")
        print("PASS: async pull epoch guard and removeAll")

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
        var waitStarts: [(String, Int)] = []
        let waited = CommandDirectory(startPull: { id, epoch in waitStarts.append((id, epoch)) })
        let cold = Task { try await waited.ensureReadyAsync("s1") }
        await spin { !waitStarts.isEmpty }
        assert(waitStarts.count == 1 && waitStarts[0].0 == "s1" && waited.status("s1") == .pending, "the wait starts the pull it needs")
        let joined = Task { try await waited.ensureReadyAsync("s1") }
        await spin { (waited.entries["s1"]?.waiters.count ?? 0) == 2 }
        assert(waitStarts.count == 1, "a pending entry joins the pull in flight")
        waited.publish("s1", epoch: waitStarts[0].1, .success([descriptor("goal")]))
        let coldResult = try await cold.value
        let joinedResult = try await joined.value
        assert(coldResult == [descriptor("goal")] && joinedResult == [descriptor("goal")])
        assert(waited.status("s1") == .ready)
        print("PASS: the strong wait serves a cold entry and joins a pending pull")

        // A failed pull rejects the wait (the reference's "never a silent
        // downgrade") and does not poison the key: the next wait repulls.
        var failWaitStarts: [(String, Int)] = []
        let failingWait = CommandDirectory(startPull: { id, epoch in failWaitStarts.append((id, epoch)) })
        let rejected = Task { try await failingWait.ensureReadyAsync("s1") }
        await spin { !failWaitStarts.isEmpty }
        failingWait.publish("s1", epoch: failWaitStarts[0].1, .failure(PullError(message: "down")))
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
        failingWait.publish("s1", epoch: failWaitStarts[1].1, .success([descriptor("recovered")]))
        let retriedResult = try await retried.value
        assert(retriedResult == [descriptor("recovered")])
        print("PASS: a failed warmup rejects and the next wait repulls")

        // A tear-down wakes the wait instead of stranding it, so a wait can
        // never outlive the connection it was started for.
        var tornStarts: [(String, Int)] = []
        let torn = CommandDirectory(startPull: { id, epoch in tornStarts.append((id, epoch)) })
        let stranded = Task { try await torn.ensureReadyAsync("s1") }
        await spin { !tornStarts.isEmpty }
        torn.removeAll()
        await spin { tornStarts.count == 2 }
        assert(torn.status("s1") == .pending, "the woken wait re-reads the dropped entry and repulls")
        torn.publish("s1", epoch: tornStarts[1].1, .success([descriptor("after-teardown")]))
        let strandedResult = try await stranded.value
        assert(strandedResult == [descriptor("after-teardown")])
        print("PASS: removeAll wakes a waiting strong wait")
    }
}
