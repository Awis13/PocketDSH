import Foundation

/// Offline checks for the composer's Return-key routing: where plain Enter and
/// Command-Enter send the typed line, on both backends and in every terminal
/// state. The file compiles the production key table with the production
/// backend enum, so the routing the views program cannot drift from the rule
/// it encodes (DSH-TERMINAL C4): plain Enter runs the shell, Command-Enter
/// asks the agent, on both backends.
@main struct ComposerKeyRoutingChecks {
    static func main() throws {
        // The shell panel, on both backends: a live terminal with the input
        // mode active. Plain Enter is the shell's there; Command-Enter is the
        // agent's.
        for backend in [ComposerBackend.dsh, .nativeHarness] {
            assert(ComposerKeyRouting.plainReturn(backend: backend, terminalAvailable: true, terminalInput: true) == .shell,
                   "\(backend): plain Enter takes the shell while the terminal input mode is active")
            assert(ComposerKeyRouting.commandReturn(backend: backend, terminalAvailable: true, terminalInput: true) == .agent,
                   "\(backend): Command-Enter asks the agent while the terminal input mode is active")
        }
        print("PASS: plain Enter runs the shell, Command-Enter asks the agent, on both backends")

        // A terminal backend whose input mode is off - the chat panel. Plain
        // Enter stays the agent's, exactly as before; Command-Enter was always
        // the agent's.
        for backend in [ComposerBackend.dsh, .nativeHarness] {
            assert(ComposerKeyRouting.plainReturn(backend: backend, terminalAvailable: true, terminalInput: false) == .agent,
                   "\(backend): plain Enter stays the agent's while the input mode is off")
            assert(ComposerKeyRouting.commandReturn(backend: backend, terminalAvailable: true, terminalInput: false) == .agent,
                   "\(backend): Command-Enter stays the agent's while the input mode is off")
        }
        print("PASS: the terminal backends' chat panel keeps plain Enter on the agent")

        // The DSH backend before its terminal is available - no plugin ticket.
        // Neither chord may reach the shell, whatever the saved input mode
        // says: that composer is the agent's in every state.
        for terminalInput in [false, true] {
            assert(ComposerKeyRouting.plainReturn(backend: .dsh, terminalAvailable: false, terminalInput: terminalInput) == .agent,
                   "a terminal-less DSH backend keeps plain Enter on the agent")
            assert(ComposerKeyRouting.commandReturn(backend: .dsh, terminalAvailable: false, terminalInput: terminalInput) == .agent,
                   "a terminal-less DSH backend keeps Command-Enter on the agent")
        }
        print("PASS: a terminal-less DSH backend never hands the shell a Return")
    }
}
