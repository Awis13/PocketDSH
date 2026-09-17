import Foundation

/// Offline checks for the composer's command routing: which slash names the
/// editor owns on which backend, and which path one submitted line takes. The
/// file compiles the production routing table with the production catalog wire
/// types, so the DSH /compact decision, the palette dedupe and the frozen
/// dispatch rule cannot drift apart.
@main struct ComposerCommandRoutingChecks {
    static func json(_ s: String) -> JSON { try! JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }
    /// One catalog descriptor. `input == nil` is the bare command the DSH
    /// `compact` registration declares (dsh-command-compact lib/index.js). Each
    /// command is a separate function so a bare descriptor never aliases a
    /// claimed one by value.
    static func full(_ name: String, hint: String) -> CommandDescriptor {
        CommandDescriptor(json(#"{"name":"\#(name)","description":"d","input":{"hint":"\#(hint)"}}"#))
    }
    static func bare(_ name: String) -> CommandDescriptor {
        CommandDescriptor(json(#"{"name":"\#(name)","description":"d"}"#))
    }
    static func row(_ rows: [ComposerPaletteRow], _ name: String) -> ComposerPaletteRow? {
        rows.first { $0.name == name }
    }
    /// The exact copy the four local rows must keep.
    static let localTable = [("/view", "Switch chat / terminal"), ("/model", "Search models"), ("/new", "New task in default workspace"), ("/compact", "Compact model context")]

    static func main() throws {
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // The table itself: exact names and copy, in palette order.
        assert(ComposerCommandRouting.commands.map(\.name) == localTable.map { $0.0 },
               "the local command table is the composer's four names in order")
        assert(ComposerCommandRouting.commands.map(\.detail) == localTable.map { $0.1 },
               "the local command copy is unchanged")
        print("PASS: the composer's local command table is the one source of the four names")

        // Availability: /view, /model and /new are local on both backends;
        // /compact only on the Native Harness.
        for backend in [ComposerBackend.dsh, .nativeHarness] {
            for name in ["/view", "/model", "/new"] {
                assert(ComposerCommandRouting.localCommand(for: name, backend: backend) != nil,
                       "\(name) stays a local command on \(backend)")
            }
        }
        assert(ComposerCommandRouting.localCommands(for: .nativeHarness).map(\.name) == localTable.map { $0.0 },
               "the native backend offers all four local rows")
        assert(ComposerCommandRouting.localCommands(for: .dsh).map(\.name) == ["/view", "/model", "/new"],
               "the DSH backend offers no local /compact row")
        assert(ComposerCommandRouting.localCommand(for: "/compact", backend: .dsh) == nil,
               "a local /compact on the DSH backend would shadow the host command")
        assert(ComposerCommandRouting.localCommand(for: "/compact", backend: .nativeHarness)?.detail == "Compact model context",
               "the native backend keeps the local /compact row and its copy")
        print("PASS: /compact is a local command on the native backend only")

        // DSH: a bare typed /compact line belongs to the host's command path.
        assert(ComposerCommandRouting.route(line: "/compact", backend: .dsh) == .server,
               "a bare /compact on DSH routes to the server command, never to local compaction")
        assert(ComposerCommandRouting.route(line: "  /compact \n", backend: .dsh) == .server,
               "the route is taken from the trimmed line")
        assert(ComposerCommandRouting.route(line: "/compact\n", backend: .nativeHarness)
               == .local(ComposerCommandRouting.commands[3]),
               "the same line on the native backend is the editor's own compaction")
        print("PASS: a bare typed /compact routes to the server on DSH and to the editor on the native host")

        // The bare-token rule: a local command acts on its BARE token only -
        // the reference's own contributions resolve exactly that way
        // (`matchEnter`'s `if (!bare) return void 0`, dsh-client-ui-commands
        // client.js:725) - so a typed name carrying trailing arguments never
        // resolves locally. Such a line falls through exactly as it did before
        // this table existed: to the DSH command path, whose commandClaimsLine
        // is what refuses the arguments on a command declaring no input line,
        // or to the ordinary message path on the native backend, because
        // nothing claims it there.
        let compact = bare("compact")
        assert(!commandClaimsLine("/compact now", descriptor: compact),
               "a command declaring no input line does not claim a line with trailing arguments")
        assert(!commandClaimsLine("/view x", descriptor: bare("view")),
               "the same rule holds for the editor's own names: a /view-shaped bare descriptor claims no arguments")
        assert(commandClaimsLine("/compact", descriptor: compact),
               "the bare token is claimed while the catalog serves the command")
        assert(commandClaimsLine("/compact now", descriptor: full("compact", hint: "reason")),
               "a command declaring an input line claims its arguments")
        assert(ComposerCommandRouting.route(line: "/compact now", backend: .dsh) == .server,
               "with arguments the DSH line belongs to the command path, not to a local route")
        assert(ComposerCommandRouting.route(line: "/compact now", backend: .nativeHarness) == .none,
               "native /compact with arguments is an ordinary message, never an editor compaction")
        for line in ["/view x", "/model sonnet", "/new approach for the parser"] {
            assert(ComposerCommandRouting.route(line: line, backend: .dsh) == .server,
                   "\(line): the DSH backend leaves the argument-bearing line to its command path")
            assert(ComposerCommandRouting.route(line: line, backend: .nativeHarness) == .none,
                   "\(line): the native backend leaves it to the ordinary message path")
        }
        // The same names still act as bare tokens - the rule is about the
        // arguments, not about disabling the local rows.
        assert(ComposerCommandRouting.route(line: " /view \n", backend: .dsh)
               == .local(ComposerCommandRouting.commands[0]),
               "a bare, whitespace-padded /view stays local on DSH")
        assert(ComposerCommandRouting.route(line: " /view \n", backend: .nativeHarness)
               == .local(ComposerCommandRouting.commands[0]),
               "and on the native backend")
        print("PASS: a local command acts on its bare token only; trailing arguments fall through on both backends")

        // DSH: a ready catalog's bare /compact row runs detached, at once, with
        // no "name + " claim - the row declares no input line.
        let rows = ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [compact], query: "/comp")
        guard let compactRow = row(rows, "/compact") else { fatalError("the catalog row must be offered") }
        assert(compactRow.descriptor == compact, "the row carries the catalog descriptor the run path needs")
        assert(compactRow.descriptor?.input == nil, "the DSH compact registration declares no input descriptor")
        assert(ComposerCommandRouting.route(line: compactRow.name, backend: .dsh) == .server,
               "picking the catalog row takes the server path")
        // The frozen dispatch rule the view applies to a .server route: an
        // input-less descriptor neither claims the composer nor waits.
        assert(compactRow.descriptor?.input == nil, "so the row is dispatched immediately, not completed into argument position")
        print("PASS: pick a bare /compact from a ready DSH catalog and it runs one server dispatch")

        // Native: /compact works from the palette row as well as from the
        // keyboard, and never takes the server path.
        let nativeRows = ComposerCommandRouting.paletteRows(backend: .nativeHarness, catalog: [compact], query: "/comp")
        guard let nativeCompact = row(nativeRows, "/compact") else { fatalError("the native row must be offered") }
        assert(nativeCompact.descriptor == nil, "the native row is the local entry, not the catalog's")
        assert(ComposerCommandRouting.route(line: nativeCompact.name, backend: .nativeHarness)
               == .local(ComposerCommandRouting.commands[3]),
               "the native palette row runs local compaction")
        assert(ComposerCommandRouting.route(line: "/compact", backend: .nativeHarness) != .server,
               "the native backend never reaches the server command path")
        print("PASS: /compact on the native backend is local from both entry points")

        // The raw-input rule (a running terminal program owns the line, so the
        // editor's /compact stands down) is NativeCompactionInfo's own check:
        // Tests/NativeContextChecks.swift pins it in check-native.sh, which runs
        // beside this file. It is deliberately NOT repeated here - the routing
        // table below never consults terminalRunning, so a copy in this file
        // would assert nothing about routing.

        // The empty catalog snapshot a cold, pending or failed directory
        // contributes adds no row on either backend, and no local /compact
        // appears on DSH to stand in for it. The palette is state-blind: it
        // renders the snapshot its caller holds, so the same empty snapshot is
        // exactly what every one of those three states contributes. The store's
        // strong wait, not this palette, reports the pull's real outcome.
        for query in ["/", "/comp", "/compact"] {
            let dsh = ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [], query: query)
            assert(row(dsh, "/compact") == nil,
                   "\(query): an empty DSH catalog adds no /compact row - the catalog is the only source of that name")
            assert(ComposerCommandRouting.route(line: "/compact", backend: .dsh) == .server,
                   "\(query): the typed line still belongs to the store's strong-waiting command path")
            // Every one of these queries prefixes the native row, so every
            // iteration asserts it - nothing is skipped silently.
            let native = ComposerCommandRouting.paletteRows(backend: .nativeHarness, catalog: [], query: query)
            assert(row(native, "/compact")?.descriptor == nil,
                   "\(query): the native palette still offers its own local /compact row, never a catalog one")
            assert(native.allSatisfy { $0.descriptor == nil },
                   "\(query): an empty catalog contributes no row on the native backend either")
        }
        // Only a catalog that actually serves /compact produces the row.
        let served = ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [bare("compact")], query: "/compact")
        assert(row(served, "/compact")?.descriptor != nil,
               "the row appears exactly when the catalog serves the descriptor")
        assert(ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [bare("goal")], query: "/compact").isEmpty,
               "another command's descriptor never stands in for /compact")
        print("PASS: an empty catalog snapshot (cold, pending or failed) adds no /compact row and no local fallback")

        // Ordinary commands: unchanged on both backends.
        for backend in [ComposerBackend.dsh, .nativeHarness] {
            assert(ComposerCommandRouting.route(line: "/view", backend: backend)
                   == .local(ComposerCommandRouting.commands[0]), "/view is local on \(backend)")
            assert(ComposerCommandRouting.route(line: "/model", backend: backend)
                   == .local(ComposerCommandRouting.commands[1]), "/model is local on \(backend)")
            assert(ComposerCommandRouting.route(line: "/new", backend: backend)
                   == .local(ComposerCommandRouting.commands[2]), "/new is local on \(backend)")
        }
        assert(ComposerCommandRouting.route(line: "/nope", backend: .dsh) == .server,
               "an unknown DSH command still takes the store's reporting command path")
        assert(ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [], query: "/nope").isEmpty,
               "an unknown command has no local row")
        assert(ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [bare("goal")], query: "/nope").isEmpty,
               "and no catalog row either")
        assert(ComposerCommandRouting.route(line: "hello", backend: .dsh) == .none, "a plain line has no route")
        assert(ComposerCommandRouting.route(line: "/", backend: .dsh) == .none, "a bare slash is not a command")
        print("PASS: /view, /model and /new resolve locally while unknown names do not")

        // A server command declaring an input line still claims the composer
        // with "name + " and is not dispatched immediately; a catalog row whose
        // name collides with an available local name is dropped, local wins.
        let goal = full("goal", hint: "goal [text]")
        let goalRows = ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [goal], query: "/go")
        assert(row(goalRows, "/goal")?.detail == "goal [text]",
               "a row declaring an input line shows its hint")
        assert(row(goalRows, "/goal")?.descriptor?.input != nil,
               "so the run path claims the composer instead of dispatching at once")
        assert(ComposerCommandRouting.route(line: "/goal do it", backend: .dsh) == .server,
               "a claimed line reaches the store with its arguments")
        let hintFallback = ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [full("goal", hint: "")], query: "/go")
        assert(row(hintFallback, "/goal")?.detail == "d", "an empty hint falls back to the description")
        let collided = ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [bare("view"), bare("compact")], query: "/")
        assert(row(collided, "/view")?.descriptor == nil, "the local /view row wins the collision and keeps no descriptor")
        assert(collided.filter { $0.name == "/view" }.count == 1, "the colliding catalog row is dropped, not duplicated")
        let nativeCollided = ComposerCommandRouting.paletteRows(backend: .nativeHarness, catalog: [bare("compact")], query: "/compact")
        assert(nativeCollided.count == 1 && nativeCollided[0].descriptor == nil,
               "the native local /compact row wins the collision with the host's descriptor")
        let sorted = ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [bare("zeta"), bare("alpha")], query: "/")
        assert(sorted.map(\.name) == ["/view", "/model", "/new", "/alpha", "/zeta"],
               "local rows come first, then catalog rows sorted by name")
        // Swift's hasPrefix folds case, so the lowercasing is a no-op for ASCII
        // names; pin the outcome rather than the implementation detail.
        assert(ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [], query: "/MODEL").map(\.name) == ["/model"],
               "the prefix filter keeps its behaviour for an upper-cased query")
        assert(ComposerCommandRouting.paletteRows(backend: .dsh, catalog: [], query: "/mo").map(\.name) == ["/model"],
               "a partial query still filters by prefix")
        print("PASS: hint display, local-wins dedupe and name sorting are unchanged")

        // Callsite guard: scripts/check.sh cannot compile the SwiftUI view, so
        // assert the view actually consumes the routing table instead of
        // carrying its own copy of the old behaviour.
        let view = try String(contentsOf: repo.appendingPathComponent("PocketDSH/HarnessView.swift"), encoding: .utf8)
        assert(!view.contains("localCommands"), "HarnessView declares no local command table of its own")
        assert(view.contains("ComposerCommandRouting.route("), "the view routes lines through ComposerCommandRouting")
        assert(view.contains("ComposerCommandRouting.paletteRows("), "the view builds its palette through ComposerCommandRouting")
        // The backend ARGUMENT is pinned at every callsite, not just the call:
        // a hard-coded .dsh anywhere here dead-ends a native /compact in the
        // store's `case .server: guard let descriptor else { return }` - the
        // exact bug this table exists to prevent - while the rest of the suite
        // stays green.
        assert(view.contains("private var composerBackend: ComposerBackend { store.usesNativeHarness ? .nativeHarness : .dsh }"),
               "the view still derives the backend from the live connection instead of a constant")
        assert(view.contains("ComposerCommandRouting.route(line: suggestion.name, backend: composerBackend)"),
               "the palette row is routed for the backend the view is on")
        assert(view.contains("ComposerCommandRouting.route(line: command, backend: composerBackend)"),
               "the typed-line path resolves through the same resolver, for the same backend")
        assert(view.contains("ComposerCommandRouting.paletteRows(backend: composerBackend, catalog: store.commandCatalog, query: store.draft)"),
               "the palette rows are built for the backend the view is on")
        assert(!view.contains("case \"/compact\": Task { await store.compactContext(fromEditor: true) }"),
               "no backend-independent /compact branch may remain in the view")
        assert(view.contains("case \"/compact\":"),
               "the local table's /compact keeps its own case instead of a default arm")
        // The one local compaction call the view may make is inside the local
        // route's own /compact case; a second one would be a resurrected branch.
        let compactionCalls = view.components(separatedBy: "store.compactContext(fromEditor: true)").count - 1
        assert(compactionCalls == 1, "the view calls local compaction exactly once, from the local route")
        // The typed-line path itself: no backend-independent /compact branch may
        // be resurrected ahead of the route, including one that delegates to the
        // local arm through runCommand. sendPrompt reaches runCommand exactly
        // twice - the picked palette row and the row the route resolved - and
        // the only call before the route line is the palette pick.
        let promptParts = view.components(separatedBy: "private func sendPrompt() {")
        assert(promptParts.count == 2, "HarnessView declares sendPrompt exactly once")
        let sendPrompt = promptParts.count == 2
            ? promptParts[1].components(separatedBy: "\n    private func ")[0]
            : ""
        assert(sendPrompt.components(separatedBy: "runCommand(").count - 1 == 2,
               "sendPrompt reaches runCommand exactly twice: the palette pick and the routed local row")
        assert(sendPrompt.contains("runCommand(commandMatches[min(commandIndex, commandMatches.count - 1)])"),
               "the palette pick is the call that runs the highlighted row")
        assert(sendPrompt.contains("runCommand(ComposerPaletteRow(name: local.name, detail: local.detail, descriptor: nil))"),
               "the typed line runs the row its route resolved, never a hand-built one")
        let promptBeforeRoute = sendPrompt.components(separatedBy: "ComposerCommandRouting.route(line: command, backend: composerBackend)")
        assert(promptBeforeRoute.count == 2, "sendPrompt routes the typed line exactly once")
        assert(promptBeforeRoute[0].components(separatedBy: "runCommand(").count - 1 == 1,
               "no hand-written runCommand branch precedes the route: only the palette pick does")
        print("PASS: HarnessView consumes ComposerCommandRouting for the right backend and keeps no local /compact branch")
    }
}
