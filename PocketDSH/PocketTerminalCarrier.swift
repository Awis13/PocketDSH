import Foundation
import Combine

/// Client-side carrier for the Pocket Terminal plugin (the DSH leg).
///
/// It is the Swift counterpart of the plugin's C2 wire contract (see
/// plugins/dsh-pocket-terminal/stream.js): it mints the session-scoped attach
/// ticket (the capability probe), forwards each inbound C2 frame to the shared
/// NativeClient shell, and routes the shell's input / resize / interrupt
/// commands back through the plugin's unary Remote methods.
///
/// The stream itself rides the store's mux subscription (HarnessStreamSet.Kind
/// .terminal); this carrier owns only the ticket, the frame -> NativeEvent
/// mapping, and the outbound command -> method mapping. Those two mappings are
/// pure static functions so the offline checks exercise them without a live
/// transport.
@MainActor
final class PocketTerminalCarrier {
    private let api: HarnessAPI

    /// The shared shell this carrier feeds. The store sets it once the native
    /// shell exists for the DSH leg; nil means nothing is being rendered yet.
    var shell: NativeClient?

    /// The session this carrier is attached to (set by the store before probe).
    var sessionID: String?

    /// Whether the plugin is present and minted a ticket for this session.
    /// This is the capability flag the views read (supportsShell).
    private(set) var available = false

    /// The minted attach ticket: the capability proof and the write/resize key.
    private(set) var ticket: String?

    /// Last seq received; the replay cursor for re-subscribing after a drop.
    private(set) var since = 0

    init(api: HarnessAPI) { self.api = api }

    /// Mint the attach ticket for a session. A nil return means the plugin is
    /// not loaded (or the session is unknown) -> the terminal is unavailable.
    /// A non-nil return makes the terminal available.
    @discardableResult
    func probe(session: String) async -> String? {
        if sessionID != session { since = 0 }   // new session: full replay
        sessionID = session
        do {
            let t = try await api.authTicket(session: session)
            ticket = t; available = true; return t
        } catch {
            ticket = nil; available = false; return nil
        }
    }

    func stop() {
        available = false
        ticket = nil
        shell = nil
    }

    // MARK: - Inbound: C2 wire frame -> [NativeEvent] (pure)

    /// Map one C2 wire frame to the NativeEvent(s) the shared shell must
    /// receive. The frame is exactly the JSON object the plugin's attach
    /// stream yields (type / seq / sessionId / data / blockId / ...). Unknown
    /// ops map to [] (ignored, never an error).
    static func nativeEvents(frame: JSON, session: String) -> [NativeEvent] {
        switch frame["type"].string {
        case "open":
            let sid = frame["sessionId"].string
            let cols = frame["cols"].int
            let rows = frame["rows"].int
            // opened: connect + reset the shell; synced: clear the syncing
            // spinner and apply the PTY geometry (mirrors the native leg).
            return [
                NativeEvent(op: "opened", session: sid.isEmpty ? session : sid),
                NativeEvent(op: "synced", rows: rows > 0 ? rows : 24, columns: cols > 0 ? cols : 80)
            ]
        case "data":
            let b64 = frame["data"].string
            guard !b64.isEmpty, let data = Data(base64Encoded: b64) else { return [] }
            return [NativeEvent(op: "pty", bytes: data)]
        case "blockStart":
            let id = frame["blockId"].string
            guard !id.isEmpty else { return [] }
            return [NativeEvent(op: "blockStart", id: id, text: frame["text"].string)]
        case "blockEnd":
            let id = frame["blockId"].string
            guard !id.isEmpty else { return [] }
            let code = frame["exitCode"].int
            return [NativeEvent(op: "blockEnd", id: id, text: frame["text"].string,
                                exitCode: code, failed: code != 0)]
        case "exit":
            return [NativeEvent(op: "ptyExit", text: frame["signal"].string,
                                exitCode: frame["exitCode"].int)]
        case "error":
            let raw = frame["message"].string
            let fallback = frame["code"].string
            let message = raw.isEmpty ? fallback : raw
            return [NativeEvent(op: "ptyExit", text: message.isEmpty ? "terminal error" : message)]
        default:
            return []
        }
    }

    /// Forward one C2 wire frame to the shell and advance the replay cursor.
    func receive(_ frame: JSON) {
        let seq = frame["seq"].int
        if seq > since { since = seq }
        guard let sid = sessionID else { return }
        for event in Self.nativeEvents(frame: frame, session: sid) {
            shell?.receive(event)
        }
    }

    // MARK: - Outbound: NativeCommand -> (endpoint, args) (pure)

    /// The (endpoint, wire args) a shell command maps to. Input and resize use
    /// the plugin's unary Remote methods; interrupt is a classic Ctrl-C byte,
    /// so it rides write. nil = the command is a no-op on this leg.
    ///
    /// The wire field for the session parameter is `sessionId` (the gateway
    /// resolves it to a Session via the session lookup), and `data` is a UTF-8
    /// string per the C2 contract.
    static func outbound(_ command: NativeCommand, session: String, ticket: String) -> (endpoint: String, args: [String: JSON])? {
        switch command.op {
        case "input":
            let data = command.bytes.map { String(decoding: $0, as: UTF8.self) } ?? command.text ?? ""
            return ("pocketTerminal/write", ["sessionId": .string(session), "data": .string(data), "ticket": .string(ticket)])
        case "resize":
            guard let cols = command.columns, let rows = command.rows else { return nil }
            return ("pocketTerminal/resize", ["sessionId": .string(session), "cols": .number(Double(cols)), "rows": .number(Double(rows)), "ticket": .string(ticket)])
        case "interrupt":
            return ("pocketTerminal/write", ["sessionId": .string(session), "data": .string("\u{03}"), "ticket": .string(ticket)])
        default:
            return nil
        }
    }

    /// Send one shell command back through the plugin. A no-op when the
    /// terminal is unavailable (the shell is hidden then) or the command maps
    /// to nothing. Failures are swallowed: the command is best-effort and the
    /// next frame re-synchronises the UI.
    func send(_ command: NativeCommand) async {
        guard available, let sid = sessionID, let ticket = ticket,
              let (endpoint, args) = Self.outbound(command, session: sid, ticket: ticket) else { return }
        _ = try? await api.rpc(endpoint, args: args)
    }
}
