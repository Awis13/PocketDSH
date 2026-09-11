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
    static func main() throws {
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

        struct PullError: Error, Equatable { let message: String }

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
    }
}
