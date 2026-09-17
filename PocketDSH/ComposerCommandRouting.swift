import Foundation

// The composer's command routing decision: which slash names the editor itself
// owns on which backend, and how one submitted line is routed. Self-contained
// value types plus pure functions - no PocketStore, no SwiftUI/UIKit - so the
// offline checks can compile this file together with CommandCatalog.swift and
// exercise the production decision table without the app.
//
// The split it encodes is the reference's. The Native Harness host has no
// command registry at all, so /view, /model, /new and /compact are editor
// actions there. On the DSH backend the reference's palette is the host
// catalog PLUS its own contributions: `candidates` builds the catalog rows
// and then appends every available contribution, deduping on the name and
// throwing on a collision (dsh-client-ui-commands client.js:633-655), while
// `hostDescription`/`dispatch`/`matchSpace` (:657-700) decide what a picked
// row does. This file is the app's analogue of those contributions: its local
// rows come first and a colliding catalog row is dropped. Such a local name
// acts on the BARE token only - `matchEnter` returns early for a contribution
// that is not bare (:725) and does the same for a bare host command (:751) -
// while a host command declaring an input line claims the trimmed line with
// its arguments (:747-750). The local /compact entry therefore exists on the
// native backend only: on DSH the server registers `compact` itself
// (dsh-command-compact lib/index.js) and the catalog row is the only source of
// that name.

/// The two backends the composer routes for. The caller passes the value in
/// (the app derives it from `store.usesNativeHarness`); nothing here reads a
/// store, an endpoint or its URL scheme, so the checks drive both sides
/// without a store or a transport.
enum ComposerBackend: Equatable {
    /// DSH Remote RPC: the session's command catalog serves the menu rows.
    case dsh
    /// Swift Native Harness: the editor owns every slash name it knows.
    case nativeHarness
}

/// One command the composer runs itself. `name` carries the leading slash and
/// is the display copy; the palette renders both verbatim.
struct ComposerLocalCommand: Equatable {
    var name: String
    var detail: String
}

/// The routing decision for one submitted line, as a value the run path can
/// switch on. It answers only "who owns this line"; the frozen dispatch
/// semantics (`descriptor.input != nil` claims the composer with the leading
/// token, a bare server command executes detached) stay with the caller that
/// holds the descriptor.
enum ComposerCommandRoute: Equatable {
    /// A command the editor itself runs on this backend.
    case local(ComposerLocalCommand)
    /// The DSH command path owns the line; the store strong-waits the catalog
    /// before deciding, so this route is taken without consulting it here.
    case server
    /// Nothing claims the line: it stays an ordinary composer message.
    case none
}

enum ComposerCommandRouting {
    /// The composer's own commands, in palette order, with the copy the rows
    /// render. This is the one table: the view no longer declares its own.
    static let commands = [
        ComposerLocalCommand(name: "/view", detail: "Switch chat / terminal"),
        ComposerLocalCommand(name: "/model", detail: "Search models"),
        ComposerLocalCommand(name: "/new", detail: "New task in default workspace"),
        ComposerLocalCommand(name: "/compact", detail: "Compact model context"),
    ]

    /// The local commands this backend offers. /view, /model and /new are
    /// editor actions on both; /compact is one on the Native Harness only - on
    /// DSH the server registers the same name, so a local entry would shadow
    /// the host command instead of running it.
    static func localCommands(for backend: ComposerBackend) -> [ComposerLocalCommand] {
        switch backend {
        case .dsh: return commands.filter { $0.name != "/compact" }
        case .nativeHarness: return commands
        }
    }

    /// The local row for one command NAME (`/view`, `/compact`, ...), or nil
    /// when this backend does not own that name. The lookup itself is blind to
    /// trailing input: `route` applies the bare-token rule before asking, and a
    /// caller holding a parsed name (a palette row, whose name is always bare)
    /// may ask directly.
    static func localCommand(for name: String, backend: ComposerBackend) -> ComposerLocalCommand? {
        localCommands(for: backend).first { $0.name == name }
    }

    /// One submitted line's route. A line that does not parse as a command
    /// (no leading slash, an invalid name, a bare "/") is never a route.
    ///
    /// A local command acts on its BARE token only - the reference resolves
    /// its own contributions exactly that way (`matchEnter`'s `if (!bare)
    /// return void 0`, dsh-client-ui-commands client.js:725), and a host
    /// command's detached execute is bare-only too (:751) - so a name carrying
    /// trailing arguments is never local. Such a line falls through exactly as
    /// it did before this table existed: on the DSH backend to the host
    /// command path, whose `commandClaimsLine` is what refuses trailing
    /// arguments on a command declaring no input line, and on the native
    /// backend to the ordinary message path, because nothing claims it.
    static func route(line: String, backend: ComposerBackend) -> ComposerCommandRoute {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = parseCommand(trimmed) else { return .none }
        let name = "/" + parsed.name
        if parsed.rawInput.isEmpty, let local = localCommand(for: name, backend: backend) { return .local(local) }
        return backend == .dsh ? .server : .none
    }

    /// The palette rows for one composer draft: the backend's local rows first,
    /// then the catalog snapshot sorted by name. A catalog row colliding with an
    /// available local name is dropped - the local entry wins - and a cold,
    /// pending or failed catalog simply contributes no rows, because the catalog
    /// is the only source of server candidates. The palette is blind to the
    /// catalog's state; the view's own status copy is what reports a cold or
    /// failed pull.
    ///
    /// A row with an input line shows its hint and falls back to the
    /// description when the hint is empty; a bare command shows its
    /// description. The reference's candidate carries the description always
    /// and the hint only for a command that declares one (dsh-client-ui-commands
    /// client.js:638-645).
    static func paletteRows(backend: ComposerBackend, catalog: [CommandDescriptor], query: String) -> [ComposerPaletteRow] {
        let local = localCommands(for: backend)
        var rows = local.map { ComposerPaletteRow(name: $0.name, detail: $0.detail, descriptor: nil) }
        let localNames = Set(rows.map(\.name))
        for descriptor in catalog.sorted(by: { $0.name < $1.name }) {
            let name = "/" + descriptor.name
            guard !localNames.contains(name) else { continue }
            let hint = descriptor.input?.hint ?? ""
            rows.append(ComposerPaletteRow(name: name, detail: hint.isEmpty ? descriptor.description : hint, descriptor: descriptor))
        }
        let lowered = query.lowercased()
        return rows.filter { $0.name.hasPrefix(lowered) }
    }
}

/// One composer-palette row. A local entry carries no catalog descriptor; a row
/// the session's catalog serves carries it, so the run path can tell a command
/// that claims an argument from a bare one.
struct ComposerPaletteRow: Equatable {
    var name: String
    var detail: String
    var descriptor: CommandDescriptor?
}
