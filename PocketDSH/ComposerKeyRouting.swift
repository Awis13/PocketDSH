import Foundation

/// Where the composer's Return keys send the typed line. Self-contained value
/// types and pure functions - no PocketStore, no SwiftUI/UIKit - so the
/// offline checks can compile this file with ComposerCommandRouting.swift and
/// exercise the production decision table without the app.
///
/// The rule the table encodes (DSH-TERMINAL C4): plain Enter runs the line in
/// the shell, Command-Enter asks the agent, on both backends. Plain Return
/// therefore takes the shell only when the backend has a live terminal - the
/// native leg always, the DSH leg only while the Pocket Terminal plugin minted
/// a ticket - AND the terminal input mode is active; on both legs that state
/// is the shell panel. In every other state plain Return behaves exactly as
/// before: it sends the draft to the agent. Command-Return always asks the
/// agent, on both backends and in every shell state.
///
/// The views consume the table at the composer's single branching point:
/// DesktopPromptTextView's keyCommands hand plain Return to the `send` closure
/// and Command-Return to the `sendToAgent` closure, and the construction
/// sites pick those closures from this table.

/// Where one Return chord sends the composer's typed line.
enum ComposerReturnTarget: Equatable {
    /// The line goes to the shell (the PTY input path).
    case shell
    /// The line is sent to the agent.
    case agent
}

enum ComposerKeyRouting {
    /// Plain Return (no modifier): the shell while a terminal is reachable and
    /// its input mode is active, the agent in every state the shell cannot take
    /// the line - a terminal-less backend, and a terminal backend whose input
    /// mode is off.
    static func plainReturn(backend: ComposerBackend, terminalAvailable: Bool, terminalInput: Bool) -> ComposerReturnTarget {
        guard terminalAvailable && terminalInput else { return .agent }
        return .shell
    }

    /// Command-Return: the agent, on both backends and in every shell state.
    /// The shell never sees the Command chord.
    static func commandReturn(backend: ComposerBackend, terminalAvailable: Bool, terminalInput: Bool) -> ComposerReturnTarget {
        .agent
    }
}
