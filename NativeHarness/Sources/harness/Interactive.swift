import Foundation
import HarnessCore
import Darwin

enum Interactive {
    struct Command: Decodable {
        let op: String
        let id: String?
        let prompt: String?
        let allow: Bool?
        let command: String?
        let blockID: String?
        let ptyID: String?
        let bytes: String?
        let rows: Int?
        let columns: Int?
        let after: Int64?
        let maxBytes: Int?
    }
    struct Reply: Encodable {
        let control: String
        var receipt: CommandReceipt?
        var status: DriverStatus?
        var ids: [String]?
        var removed: Bool?
        var error: String?
        var block: CommandBlock?
        var context: String?
        var terminals: [TerminalInfo]?
        var observation: TerminalRead?
        var operationID: String?
        var compaction: CompactionReceipt?
    }
    static func emit(_ reply: Reply) {
        if let data = try? JSONEncoder().encode(reply) {
            FileHandle.standardError.write(data + Data([10]))
        }
    }
    static func run(engine: SessionEngine, approvals: ApprovalController, terminal: TerminalSession, workspace: String, observations: TerminalObservations, prompt: String?, resume: Bool,
                    update: @escaping @Sendable (LiveUpdate) -> Void) async throws {
        let pty = PTYControl(workspace: workspace, observations: observations)
        let driver = SessionDriver(engine: engine, onUpdate: update)
        signal(SIGINT, SIG_IGN)
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interruption.setEventHandler(handler: { @Sendable in Task { await driver.stop(); await terminal.cancel() } })
        interruption.resume()
        defer { interruption.cancel() }
        if let prompt { _ = try await driver.submit(prompt: prompt) }
        else if resume { await driver.resume() }
        // Stdin is a local developer control channel, not a remote API.
        await Task.detached {
            var terminalReplies: [Task<Void, Never>] = []
            var compactionReplies: [Task<Void, Never>] = []
            while let line = readLine() {
                do {
                    guard line.utf8.count <= 300_000 else { throw HarnessError.invalid("Control line too large") }
                    let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
                    switch command.op {
                    case "pty-inspect": emit(Reply(control: "ptyInspection", terminals: observations.list()))
                    case "pty-read":
                        guard let id = command.ptyID, let cursor = command.after else { throw HarnessError.invalid("ptyID and after required") }
                        emit(Reply(control: "ptyRead", observation: try observations.find(id).read(after: cursor, maxBytes: command.maxBytes ?? 16384)))
                    case "pty-open": try await pty.open(rows: command.rows ?? 24, columns: command.columns ?? 80)
                    case "pty-input": try await pty.input(id: command.ptyID, base64: command.bytes)
                    case "pty-resize":
                        guard let rows = command.rows, let columns = command.columns else { throw HarnessError.invalid("rows and columns required") }
                        try await pty.resize(id: command.ptyID, rows: rows, columns: columns)
                    case "pty-interrupt": try await pty.interrupt(id: command.ptyID)
                    case "pty-close": try await pty.close(id: command.ptyID)
                    case "queue", "steer":
                        guard let id = command.id, let prompt = command.prompt else { throw HarnessError.invalid("id and prompt required") }
                        let receipt = try await driver.submit(prompt: prompt, mode: command.op == "queue" ? .queue : .steer, commandID: id)
                        emit(Reply(control: "accepted", receipt: receipt))
                    case "shell":
                        guard let shellCommand = command.command else { throw HarnessError.invalid("command required") }
                        let work = try await terminal.start(command: shellCommand, onUpdate: update)
                        terminalReplies.append(Task {
                            do { emit(Reply(control: "shellCompleted", block: try await work.value)) }
                            catch { emit(Reply(control: "shellFailed", error: String(describing: error))) }
                        })
                        emit(Reply(control: "shellAccepted"))
                    case "shell-cancel": await terminal.cancel()
                    case "blocks": emit(Reply(control: "blocks", ids: try await terminal.blocks().map(\.id)))
                    case "context", "send-context":
                        guard let blockID = command.blockID else { throw HarnessError.invalid("blockID required") }
                        let context = try await terminal.context(blockID: blockID)
                        if command.op == "context" { emit(Reply(control: "context", context: context)) }
                        else {
                            guard let id = command.id, let prompt = command.prompt else { throw HarnessError.invalid("id and prompt required") }
                            let receipt = try await driver.submit(prompt: prompt + "\n\n" + context, commandID: id)
                            emit(Reply(control: "accepted", receipt: receipt))
                        }
                    case "approval":
                        guard let id = command.id, let allow = command.allow else { throw HarnessError.invalid("id and allow required") }
                        emit(Reply(control: "approvalAnswered", removed: await approvals.answer(id: id, allow: allow)))
                    case "pending": emit(Reply(control: "pending", ids: try await engine.pending().map(\.id)))
                    case "remove":
                        guard let id = command.id else { throw HarnessError.invalid("id required") }
                        emit(Reply(control: "removed", removed: try await engine.removePending(commandID: id)))
                    case "compact":
                        guard let id = command.id, !id.isEmpty, id.utf8.count <= 128, !id.contains("\0") else { throw HarnessError.invalid("Valid operation id required") }
                        // Keep reading stdin so cancel/status remain available during inference.
                        compactionReplies.append(Task {
                            do { emit(Reply(control: "compaction", operationID: id, compaction: try await driver.compact(operationID: id))) }
                            catch { emit(Reply(control: "compactionRejected", error: DiagnosticTrace.errorCode(error), operationID: id)) }
                        })
                    case "compactStatus":
                        guard let id = command.id else { throw HarnessError.invalid("id required") }
                        emit(Reply(control: "compaction", operationID: id, compaction: try await engine.compactionReceipt(operationID: id)))
                    case "cancel": compactionReplies.forEach { $0.cancel() }; await driver.stop(); emit(Reply(control: "cancellationRequested"))
                    case "resume": await driver.resume(); emit(Reply(control: "resumed"))
                    case "status": emit(Reply(control: "status", status: try await driver.status()))
                    default: throw HarnessError.invalid("Unknown control operation")
                    }
                } catch { emit(Reply(control: "rejected", error: String(describing: error))) }
            }
            await pty.shutdown()
            await approvals.close()
            await terminal.cancel()
            for reply in terminalReplies + compactionReplies { await reply.value }
            await driver.waitUntilIdle()
        }.value
        let status = try await driver.status()
        emit(Reply(control: "idle", status: status))
        if let code = status.errorCode { throw HarnessError.invalid("Driver stopped: \(code); pending messages retained") }
    }
}
