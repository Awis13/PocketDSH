import Foundation

/// One driver owns a session. Inbox admission is durable; runPending drains it.
/// Cancellation stops the driver and preserves unclaimed commands for explicit resume.
public actor SessionEngine {
    private let id: String
    private let store: EventStore
    private let provider: any ModelProvider
    private let tools: any ToolExecutor
    private var running = false
    private var activeTask: Task<String, Error>?
    private var trace: DiagnosticTrace?

    public func diagnostics() -> DiagnosticSnapshot? { trace?.snapshot() }

    public func cancel() {
        guard let activeTask else { return }
        trace?.record(.cancellationRequested)
        activeTask.cancel()
    }

    public init(id: String, store: EventStore, provider: any ModelProvider, tools: any ToolExecutor) {
        self.id = id; self.store = store; self.provider = provider; self.tools = tools
    }

    public func enqueue(prompt: String, mode: DeliveryMode = .queue, commandID: String = UUID().uuidString) async throws -> CommandReceipt {
        try await store.bindWorkspace(tools.workspaceIdentity, session: id)
        let receipt = try await store.enqueue(session: id, id: commandID, prompt: prompt, mode: mode)
        if !receipt.duplicate { trace?.record(mode == .queue ? .queued : .steered) }
        return receipt
    }

    public func pending() async throws -> [PendingCommand] { try await store.pending(session: id) }
    public func removePending(commandID: String) async throws -> Bool { try await store.removePending(session: id, id: commandID) }

    public func run(prompt: String, maxSteps: Int = 12,
                    onUpdate: @escaping @Sendable (LiveUpdate) -> Void = { _ in }) async throws -> String {
        try await start(prompt: prompt, maxSteps: maxSteps, onUpdate: onUpdate)
    }
    public func runPending(maxSteps: Int = 12,
                           onUpdate: @escaping @Sendable (LiveUpdate) -> Void = { _ in }) async throws -> String {
        try await start(prompt: nil, maxSteps: maxSteps, onUpdate: onUpdate)
    }
    private func start(prompt: String?, maxSteps: Int,
                       onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> String {
        guard !running else { throw HarnessError.busy }
        guard prompt == nil || !prompt!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              maxSteps > 0 else { throw HarnessError.invalid("Empty prompt or invalid step limit") }
        running = true
        let currentTrace = DiagnosticTrace(sessionID: id) { onUpdate(.diagnostic($0)) }
        trace = currentTrace
        currentTrace.record(.accepted)
        let owner = UUID().uuidString
        let task = Task { try await self.execute(prompt: prompt, maxSteps: maxSteps, owner: owner, trace: currentTrace, onUpdate: onUpdate) }
        activeTask = task
        defer { running = false; activeTask = nil }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                currentTrace.record(.cancellationRequested)
                task.cancel()
            }
            await store.releaseExecution(session: id, owner: owner)
            currentTrace.record(.completed)
            return result
        } catch {
            await store.releaseExecution(session: id, owner: owner)
            let code = DiagnosticTrace.errorCode(error)
            currentTrace.record(code == "CANCELLED" ? .cancelled : .failed, code: code)
            throw error
        }
    }

    private func save(_ events: [SessionEvent], trace: DiagnosticTrace) async throws {
        trace.record(.persisting)
        let stamped = events.map { event in
            var event = event; event.trace = trace.identifiers(); return event
        }
        try await store.append(stamped, session: id)
    }

    private func execute(prompt: String?, maxSteps: Int, owner: String, trace: DiagnosticTrace,
                         onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> String {
        trace.record(.restoring)
        try Task.checkCancellation()
        try await store.acquireExecution(session: id, owner: owner)
        try await store.bindWorkspace(tools.workspaceIdentity, session: id)
        var events = try await store.load(session: id)
        let repairs = Self.recovery(events)
        if !repairs.isEmpty { try await store.append(repairs, session: id); events += repairs }
        var history = events.compactMap(\.message)
        if let prompt { _ = try await store.enqueue(session: id, id: UUID().uuidString, prompt: prompt, mode: .queue) }
        var firstTurn = true
        var lastAnswer = ""
        do {
            while true {
                try Task.checkCancellation()
                let context = firstTurn ? trace.identifiers() : TraceContext(sessionID: trace.identifiers().sessionID, turnID: UUID().uuidString)
                let claimed = try await store.claim(session: id, owner: owner, startsTurn: true, trace: context)
                guard !claimed.isEmpty else { return lastAnswer }
                trace.startTurn(context)
                firstTurn = false
                history += claimed
                trace.record(.ready)
                var finishedTurn = false
                for _ in 0..<maxSteps {
                    try Task.checkCancellation()
                    trace.beginRequest()
                    history += try await store.claim(session: id, owner: owner, startsTurn: false, trace: trace.identifiers())
                    trace.record(.requesting)
                    let observer = RequestDiagnostics(trace)
                    let reply = try await provider.complete(messages: history, tools: tools.definitions) { update in
                        observer.observe(update)
                        onUpdate(update)
                    }
                    trace.record(.modelCompleted)
                    try Task.checkCancellation()
                    guard ["stop", "tool_calls"].contains(reply.finishReason) else {
                        throw HarnessError.provider("Incomplete model response: \(reply.finishReason)")
                    }
                    guard reply.message.role == "assistant" else { throw HarnessError.provider("Expected assistant response") }
                    let calls = reply.message.calls
                    guard Set(calls.map(\.id)).count == calls.count,
                          calls.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
                          !(calls.isEmpty && reply.finishReason == "tool_calls") else {
                        throw HarnessError.provider("Malformed tool-call response")
                    }
                    guard !calls.isEmpty || !reply.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw HarnessError.provider("Empty assistant response")
                    }
                    try await save([SessionEvent("message", message: reply.message)], trace: trace)
                    history.append(reply.message)
                    if calls.isEmpty {
                        trace.record(.persisting)
                        if try await store.finishIfUnsteered(session: id, owner: owner, trace: trace.identifiers()) {
                            lastAnswer = reply.message.content
                            finishedTurn = true
                            trace.record(.turnCompleted)
                            break
                        }
                    }
                    for call in calls {
                        try Task.checkCancellation()
                        trace.beginTool()
                        try await save([SessionEvent("tool.started", call: call)], trace: trace)
                        trace.record(.toolStarted)
                        onUpdate(.tool(call.name))
                        onUpdate(.toolCall(call))
                        let output: String
                        var failed = false
                        do {
                            let context = ToolExecutionContext(update: onUpdate, record: { event in
                                try await self.save([event], trace: trace)
                            })
                            output = try await tools.execute(call, context: context)
                            trace.record(.toolCompleted)
                        }
                        catch is CancellationError { throw CancellationError() }
                        catch { failed = true; trace.record(.toolFailed, code: DiagnosticTrace.errorCode(error)); output = "Tool error: \(error)" }
                        let result = Message(role: "tool", content: output, toolCallID: call.id)
                        try await save([SessionEvent("message", message: result)], trace: trace)
                        history.append(result)
                        onUpdate(.toolResult(id: call.id, output: output, failed: failed))
                    }
                }
                if !finishedTurn { throw HarnessError.limit }
            }
        } catch {
            // Close every unmatched tool request even on ordinary cancellation.
            // If storage fails, leave the tail open for recovery on next launch.
            let tail = try await store.load(session: id)
            let closers = Self.recovery(tail, reason: DiagnosticTrace.errorCode(error) == "CANCELLED" ? "cancelled" : "failed: \(error)")
            try await save(closers, trace: trace)
            throw error
        }
    }

    public static func recovery(_ events: [SessionEvent], reason: String = "interrupted") -> [SessionEvent] {
        var open = false
        var pending: [ToolCall] = []
        var started: Set<String> = []
        for event in events {
            if event.kind == "turn.started" { open = true; pending = []; started = [] }
            if event.kind == "turn.ended" { open = false; pending = []; started = [] }
            if let message = event.message {
                if message.role == "assistant" { pending += message.calls }
                if message.role == "tool", let id = message.toolCallID { pending.removeAll { $0.id == id } }
            }
            if event.kind == "tool.started", let call = event.call { started.insert(call.id) }
        }
        guard open else { return [] }
        return pending.map { call in
            SessionEvent("message", message: Message(role: "tool", content: started.contains(call.id)
                ? "TOOL_OUTCOME_UNKNOWN: interrupted after dispatch was recorded. Verify external state before retrying side effects."
                : "TOOL_NOT_STARTED: interrupted before dispatch was recorded.", toolCallID: call.id))
        } + [SessionEvent("turn.ended", detail: reason)]
    }
}
