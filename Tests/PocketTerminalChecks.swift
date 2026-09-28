import Foundation

/// A parked HarnessAPI for the Pocket Terminal carrier: authTicket and rpc are
/// scripted, so the probe and the outbound send run without a live transport.
@MainActor
final class TerminalFakeAPI: HarnessAPI {
    enum Ticket { case ok(String), fail(String) }
    var ticketResult: Ticket = .ok("tkt-1")
    private(set) var ticketSessions: [String] = []
    private(set) var rpcCalls: [(method: String, args: [String: JSON])] = []

    init() { super.init(base: URL(string: "https://dsn.example")!) }

    override func authTicket(session: String) async throws -> String {
        ticketSessions.append(session)
        switch ticketResult {
        case .ok(let t): return t
        case .fail(let m): throw HarnessError(message: m)
        }
    }
    override func rpc(_ method: String, args: [String: JSON]) async throws -> JSON {
        rpcCalls.append((method, args))
        return .object(["ok": .bool(true)])
    }
}

@main struct PocketTerminalChecks {
    /// Build one C2 attach frame with a type plus its fields.
    static func frame(_ type: String, _ fields: [String: JSON]) -> JSON {
        var f = fields; f["type"] = .string(type); return .object(f)
    }

    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    @MainActor
    static func run() async throws {
        try await frameToEvents()
        try await commandToOutbound()
        try await noPluginHidesShell()
        try await probeThenSend()
        print("PASS: PocketTerminalChecks")
    }

    // The C2 attach frames map onto the shell wire: open -> opened+synced
    // (geometry), data -> pty bytes, block/exit -> blocks, error -> ptyExit.
    @MainActor
    static func frameToEvents() async throws {
        let S = "sess-1"
        let open = PocketTerminalCarrier.nativeEvents(frame: frame("open", ["sessionId": .string(S), "pid": .number(7), "cwd": .string("/w"), "cols": .number(120), "rows": .number(40), "replay": .bool(false)]), session: S)
        assert(open.count == 2, "open yields opened + synced")
        assert(open[0].op == "opened" && open[0].session == S, "open -> opened for the session")
        assert(open[1].op == "synced" && open[1].columns == 120 && open[1].rows == 40, "open -> synced with the PTY geometry")

        let payload = Data("hi".utf8).base64EncodedString()
        let data = PocketTerminalCarrier.nativeEvents(frame: frame("data", ["data": .string(payload), "bytes": .number(2)]), session: S)
        assert(data.count == 1 && data[0].op == "pty" && data[0].bytes == Data("hi".utf8), "data -> pty bytes decoded from base64")

        let bs = PocketTerminalCarrier.nativeEvents(frame: frame("blockStart", ["blockId": .string("B1"), "text": .string("t")]), session: S)
        assert(bs.count == 1 && bs[0].op == "blockStart" && bs[0].id == "B1" && bs[0].text == "t", "blockStart -> blockStart id+text")

        let be0 = PocketTerminalCarrier.nativeEvents(frame: frame("blockEnd", ["blockId": .string("B1"), "text": .string("t"), "exitCode": .number(0)]), session: S)
        assert(be0.count == 1 && be0[0].op == "blockEnd" && be0[0].exitCode == 0 && be0[0].failed == false, "blockEnd code 0 -> not failed")
        let be1 = PocketTerminalCarrier.nativeEvents(frame: frame("blockEnd", ["blockId": .string("B1"), "text": .string("t"), "exitCode": .number(1)]), session: S)
        assert(be1[0].exitCode == 1 && be1[0].failed == true, "blockEnd code 1 -> failed")

        let ex = PocketTerminalCarrier.nativeEvents(frame: frame("exit", ["exitCode": .number(0)]), session: S)
        assert(ex.count == 1 && ex[0].op == "ptyExit" && ex[0].exitCode == 0, "exit -> ptyExit code")

        let er = PocketTerminalCarrier.nativeEvents(frame: frame("error", ["code": .string("E1"), "message": .string("boom")]), session: S)
        assert(er.count == 1 && er[0].op == "ptyExit" && er[0].text == "boom", "error -> ptyExit message")

        assert(PocketTerminalCarrier.nativeEvents(frame: frame("zzz", [:]), session: S).isEmpty, "unknown op -> no events")
    }

    // The shell commands map onto the plugin's unary methods: input/interrupt
    // -> write (a UTF-8 string), resize -> resize. Unmapped ops -> nil.
    @MainActor
    static func commandToOutbound() async throws {
        let S = "sess-1", T = "tkt-1"
        let inp = PocketTerminalCarrier.outbound(NativeCommand(op: "input", session: S, bytes: Data("ls\n".utf8)), session: S, ticket: T)
        assert(inp?.endpoint == "pocketTerminal/write", "input -> write")
        assert(inp?.args["data"]?.string == "ls\n", "input data is the utf8 string")
        assert(inp?.args["sessionId"]?.string == S, "input carries sessionId")
        assert(inp?.args["ticket"]?.string == T, "input carries the ticket")

        let inpt = PocketTerminalCarrier.outbound(NativeCommand(op: "input", session: S, text: "pwd"), session: S, ticket: T)
        assert(inpt?.args["data"]?.string == "pwd", "input falls back to text when bytes are absent")

        let rs = PocketTerminalCarrier.outbound(NativeCommand(op: "resize", session: S, rows: 50, columns: 150), session: S, ticket: T)
        assert(rs?.endpoint == "pocketTerminal/resize", "resize -> resize")
        assert(rs?.args["cols"]?.int == 150 && rs?.args["rows"]?.int == 50, "resize carries cols/rows")

        let it = PocketTerminalCarrier.outbound(NativeCommand(op: "interrupt", session: S), session: S, ticket: T)
        assert(it?.endpoint == "pocketTerminal/write" && it?.args["data"]?.string == "\u{03}", "interrupt -> write ctrl-c")

        assert(PocketTerminalCarrier.outbound(NativeCommand(op: "open", session: S), session: S, ticket: T) == nil, "open -> no outbound")
    }

    // No plugin: authTicket fails -> probe nil, the carrier stays unavailable,
    // so the store hides the shell.
    @MainActor
    static func noPluginHidesShell() async throws {
        let api = TerminalFakeAPI()
        api.ticketResult = .fail("not loaded")
        let carrier = PocketTerminalCarrier(api: api)
        let t = await carrier.probe(session: "sess-x")
        assert(t == nil, "no plugin -> probe nil")
        assert(!carrier.available, "no plugin -> unavailable (shell hidden)")
        assert(carrier.ticket == nil, "no plugin -> no ticket")
        assert(api.ticketSessions == ["sess-x"], "probe asked for the session ticket")
    }

    // With the plugin: probe mints the ticket, and a shell command routes
    // through the plugin's unary method carrying the ticket.
    @MainActor
    static func probeThenSend() async throws {
        let api = TerminalFakeAPI()
        api.ticketResult = .ok("tkt-9")
        let carrier = PocketTerminalCarrier(api: api)
        let t = await carrier.probe(session: "sess-1")
        assert(t == "tkt-9" && carrier.available && carrier.ticket == "tkt-9", "probe mints + records the ticket")

        await carrier.send(NativeCommand(op: "input", session: "sess-1", bytes: Data("ok\n".utf8)))
        assert(api.rpcCalls.count == 1 && api.rpcCalls[0].method == "pocketTerminal/write", "send -> write rpc")
        assert(api.rpcCalls[0].args["data"]?.string == "ok\n", "send data is the utf8 string")
        assert(api.rpcCalls[0].args["ticket"]?.string == "tkt-9", "send carries the ticket")

        await carrier.send(NativeCommand(op: "open", session: "sess-1"))
        assert(api.rpcCalls.count == 1, "unmapped command -> no rpc")
    }
}
