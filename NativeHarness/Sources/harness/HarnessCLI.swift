import Foundation
import HarnessCore
import Darwin

@main struct HarnessCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "--host" {
                let env = ProcessInfo.processInfo.environment
                guard args.count == 5, args[1] == "--workspace", args[3] == "--store",
                      let endpoint = env["HARNESS_BASE_URL"], let url = URL(string: endpoint),
                      let model = env["HARNESS_MODEL"], let token = env["HARNESS_HOST_TOKEN"] else {
                    throw HarnessError.invalid("harness --host --workspace PATH --store DATABASE; set HARNESS_BASE_URL, HARNESS_MODEL, HARNESS_HOST_TOKEN")
                }
                let provider = try CompatibleProvider(baseURL: url, model: model, apiKey: env["HARNESS_API_KEY"], disableThinking: env["HARNESS_DISABLE_THINKING"] == "1", options: ProviderOptions.environment(env))
                let store = try EventStore(path: args[4])
                let host = try NativeHost(port: UInt16(env["HARNESS_HOST_PORT"] ?? "8768") ?? 8768, token: token, workspace: args[2], model: model, provider: provider, store: store, journal: PresentationJournal(path: args[4] + ".native.sqlite"))
                try await host.start()
                print("Native host ready on 127.0.0.1:\(env["HARNESS_HOST_PORT"] ?? "8768")")
                signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
                let signals = [SIGINT, SIGTERM].map { number in
                    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                    source.setEventHandler { Task { await host.stop(); exit(0) } }; source.resume(); return source
                }
                while true {
                    try await Task.sleep(for: .seconds(3600))
                    withExtendedLifetime(signals) {}
                }
            }
            if args.first == "--terminal" {
                guard args.count == 3, args[1] == "--workspace" else {
                    throw HarnessError.invalid("Usage: harness --terminal --workspace PATH")
                }
                let result = try await TerminalForwarder.run(workspace: args[2])
                exit(result.code ?? (128 + (result.signal ?? 1)))
            }
            if args.first == "--inspect-trace" {
                guard args.count == 2 else { throw HarnessError.invalid("Usage: harness --inspect-trace FILE") }
                let report = try DiagnosticArchive.read(url: URL(fileURLWithPath: args[1]))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(report))
                print("")
                return
            }
            if args.contains("--help") || args.isEmpty {
                print("""
                harness --workspace PATH --store DATABASE --session ID --prompt TEXT [--allow-write] [--trace NEW_FILE] [--show-reasoning] [--interactive | --resume]
                harness --inspect-trace FILE
                harness --terminal --workspace PATH
                harness --host --workspace PATH --store DATABASE
                Provider: HARNESS_BASE_URL (including /v1), HARNESS_MODEL, optional HARNESS_API_KEY.
                Budget: optional HARNESS_CONTEXT_TOKENS, HARNESS_OUTPUT_TOKENS (default 4096).
                HARNESS_PROVIDER_PROFILE=llama-cpp enables bounded count/props checks; default compatible does not probe.
                HARNESS_INCLUDE_USAGE=0|1 overrides streaming usage (default on for llama-cpp, off for compatible).
                Host: HARNESS_HOST_TOKEN (at least 32 bytes), optional HARNESS_HOST_PORT (default 8768); loopback only.
                Read-only by default. Interactive one-use approvals for shell and edits. Ctrl-C cancels the foreground turn.
                """)
                return
            }
            let allowed = ["--workspace", "--store", "--session", "--prompt", "--allow-write", "--trace", "--show-reasoning", "--interactive", "--resume"]
            var options: [String: String] = [:]
            var index = 0
            while index < args.count {
                let key = args[index]
                guard allowed.contains(key), options[key] == nil else { throw HarnessError.invalid("Unknown or repeated option: \(key)") }
                if ["--allow-write", "--show-reasoning", "--interactive", "--resume"].contains(key) { options[key] = "true"; index += 1; continue }
                guard index + 1 < args.count else { throw HarnessError.invalid("Missing value for \(key)") }
                options[key] = args[index + 1]; index += 2
            }
            let env = ProcessInfo.processInfo.environment
            guard let endpoint = env["HARNESS_BASE_URL"], let url = URL(string: endpoint), let model = env["HARNESS_MODEL"],
                  let workspace = options["--workspace"], let db = options["--store"],
                  let id = options["--session"], !id.isEmpty else {
                throw HarnessError.invalid("Missing required arguments or provider environment; use --help")
            }
            let provider = try CompatibleProvider(baseURL: url, model: model, apiKey: env["HARNESS_API_KEY"], disableThinking: env["HARNESS_DISABLE_THINKING"] == "1", options: ProviderOptions.environment(env))
            let store = try EventStore(path: URL(fileURLWithPath: db).standardizedFileURL.path)
            let approvals = options["--interactive"] != nil ? ApprovalController() : nil
            let observations = TerminalObservations()
            let tools = try WorkspaceTools(root: URL(fileURLWithPath: workspace), allowWrite: options["--allow-write"] != nil, approvals: approvals, observations: options["--interactive"] == nil ? nil : observations)
            let engine = SessionEngine(id: id, store: store, provider: provider, tools: tools)
            let archive = try options["--trace"].map { try DiagnosticArchive(url: URL(fileURLWithPath: $0)) }
            let showReasoning = options["--show-reasoning"] != nil
            let interactive = options["--interactive"] != nil
            let resume = options["--resume"] != nil
            let prompt = options["--prompt"]
            guard prompt != nil || interactive || resume else { throw HarnessError.invalid("Supply --prompt, --resume or --interactive") }
            let update: @Sendable (LiveUpdate) -> Void = { update in
                    switch update {
                    case .text(let text): FileHandle.standardOutput.write(Data(text.utf8))
                    case .tool(let name): FileHandle.standardError.write(Data("\n[tool: \(name)]\n".utf8))
                    case .reasoning(let text):
                        if showReasoning { FileHandle.standardError.write(Data(text.utf8)) }
                    case .providerHeaders, .providerData, .toolCall, .toolResult: break
                    case .approval(let request):
                        if let data = try? JSONEncoder().encode(request) {
                            FileHandle.standardError.write(Data("{\"control\":\"approval\",\"request\":".utf8) + data + Data("}\n".utf8))
                        }
                    case .compaction(let receipt): Interactive.emit(.init(control: "compaction", compaction: receipt))
                    case .shell(let output):
                        if let data = try? JSONEncoder().encode(output) {
                            FileHandle.standardError.write(Data("{\"control\":\"shellOutput\",\"output\":".utf8) + data + Data("}\n".utf8))
                        }
                    case .diagnostic(let event):
                        if event.stage == .turnCompleted { FileHandle.standardOutput.write(Data([10])) }
                        let identity = event.context.requestID.map { " request=" + $0 } ?? ""
                        let status = "\n[\(event.stage.rawValue) +\(Int(event.elapsedMS))ms]\(identity)\(event.code.map { " \($0)" } ?? "")\n"
                        FileHandle.standardError.write(Data(status.utf8))
                        do { try archive?.append(event) }
                        catch { FileHandle.standardError.write(Data("[diagnostic write failed; session execution continues]\n".utf8)) }
                    }
            }
            if interactive {
                try await Interactive.run(engine: engine, approvals: approvals!, terminal: TerminalSession(store: store, session: id, tools: tools), workspace: workspace, observations: observations, prompt: prompt, resume: resume, update: update)
                return
            }
            let task = Task {
                if let prompt { return try await engine.run(prompt: prompt, onUpdate: update) }
                return try await engine.runPending(onUpdate: update)
            }
            signal(SIGINT, SIG_IGN)
            let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            // A dispatch signal handler runs off MainActor. Without Sendable,
            // Swift can inherit main() isolation and trap on the global queue.
            interruption.setEventHandler(handler: { @Sendable in task.cancel() })
            interruption.resume()
            defer { interruption.cancel() }
            _ = try await task.value
            print("")
        } catch {
            FileHandle.standardError.write(Data("\nError: \(error)\n".utf8))
            exit(1)
        }
    }
}
