import Foundation

/// One driver owns a session. Inbox admission is durable; runPending drains it.
/// Cancellation stops the driver and preserves unclaimed commands for explicit resume.
public actor SessionEngine {
    private let id: String
    private let store: EventStore
    private let provider: any ModelProvider
    private let tools: any ToolExecutor
    private var running = false
    private var compacting = false
    private var activeTask: Task<String, Error>?
    private var compactionTask: Task<CompactionReceipt, Error>?
    private let compactionPolicy: CompactionPolicy
    private var trace: DiagnosticTrace?
    private var latestBudget: ContextBudget?
    private var latestUsage: ProviderUsage?
    private var usageAnchor: UsageAnchor?

    public func isCompacting() -> Bool { compacting }
    public func diagnostics() -> DiagnosticSnapshot? { trace?.snapshot() }
    public func contextBudget() -> ContextBudget? { latestBudget }
    public func providerUsage() -> ProviderUsage? { latestUsage }

    public func cancel() {
        guard activeTask != nil || compactionTask != nil else { return }
        trace?.record(.cancellationRequested)
        activeTask?.cancel(); compactionTask?.cancel()
    }

    public init(id: String, store: EventStore, provider: any ModelProvider, tools: any ToolExecutor,
                compactionPolicy: CompactionPolicy = try! CompactionPolicy()) {
        self.id = id; self.store = store; self.provider = provider; self.tools = tools; self.compactionPolicy = compactionPolicy
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
        let currentTrace = DiagnosticTrace(sessionID: id) { event in
            if event.request != nil { onUpdate(.diagnostic(event)) }
        }
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

    public func compactionReceipt(operationID: String) async throws -> CompactionReceipt? {
        try await store.compactionReceipt(session: id, operationID: operationID)
    }

    public func compact(operationID: String, onUpdate: @escaping @Sendable (LiveUpdate) -> Void = { _ in }) async throws -> CompactionReceipt {
        guard !operationID.isEmpty, operationID.utf8.count <= 128, !operationID.contains("\0") else {
            throw HarnessError.invalid("Invalid compaction operation ID")
        }
        if let previous = try await compactionReceipt(operationID: operationID) { return previous }
        guard !running else { throw HarnessError.busy }
        running = true
        let owner = UUID().uuidString
        latestBudget = nil; latestUsage = nil
        let currentTrace = DiagnosticTrace(sessionID: id) { event in
            if event.request != nil { onUpdate(.diagnostic(event)) }
        }
        trace = currentTrace
        let task = Task {
            try Task.checkCancellation()
            try await self.store.acquireExecution(session: self.id, owner: owner)
            try await self.store.bindWorkspace(self.tools.workspaceIdentity, session: self.id)
            let source = try await self.store.load(session: self.id)
            let repairs = Self.recovery(source)
            if !repairs.isEmpty { try await self.store.append(repairs, session: self.id) }
            return try await self.performCompaction(operationID: operationID, owner: owner, trace: currentTrace, onUpdate: onUpdate)
        }
        compactionTask = task
        defer { running = false; compactionTask = nil }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            await store.releaseExecution(session: id, owner: owner)
            if result.state == .completed { usageAnchor = nil; latestBudget = result.after }
            return result
        } catch {
            await store.releaseExecution(session: id, owner: owner)
            currentTrace.record(DiagnosticTrace.errorCode(error) == "CANCELLED" ? .cancelled : .failed,
                code: DiagnosticTrace.errorCode(error))
            throw error
        }
    }

    private func performCompaction(operationID: String, owner: String, trace: DiagnosticTrace,
                                   onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> CompactionReceipt {
        onUpdate(.compaction(CompactionReceipt(operationID: operationID, state: .running)))
        do {
            let result = try await prepareCompaction(operationID: operationID, owner: owner, trace: trace, onUpdate: onUpdate)
            onUpdate(.compaction(result))
            return result
        } catch {
            let code = DiagnosticTrace.errorCode(error)
            onUpdate(.compaction(CompactionReceipt(operationID: operationID,
                state: code == "CANCELLED" ? .cancelled : .failed, code: code)))
            throw error
        }
    }

    private func prepareCompaction(operationID: String, owner: String, trace: DiagnosticTrace,
                                   onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> CompactionReceipt {
        compacting = true
        defer { compacting = false }
        try Task.checkCancellation()
        let snapshot = try await store.loadContext(session: id)
        trace.beginRequest(purpose: "compactionValidation")
        let original = try await provider.prepare(messages: snapshot.messages, tools: tools.definitions,
            requestID: trace.identifiers().requestID!)
        trace.record(.measuring)
        let before = try await provider.measure(original, anchor: nil)
        trace.setBudget(before); trace.record(.superseded)
        try Task.checkCancellation()
        var receipt = try await store.beginCompaction(session: id, owner: owner, operationID: operationID,
            sourceVersion: snapshot.version, fingerprint: original.fingerprint, before: before)
        if receipt.state != .running { return receipt }
        onUpdate(.compaction(receipt))
        do {
            let compactor = ContextCompactor(provider: provider, tools: tools.definitions, policy: compactionPolicy)
            let plan = try await compactor.prepare(snapshot: snapshot, original: original, before: before, trace: trace)
            try await compactor.revalidate(plan)
            let result = try await store.commitCompaction(session: id, owner: owner, operationID: operationID, plan: plan)
            // No cancellation check after a committed result: completion wins.
            trace.record(.completed)
            return result
        } catch {
            let code = DiagnosticTrace.errorCode(error)
            receipt.state = code == "CANCELLED" ? .cancelled : .failed
            receipt.code = code
            receipt.summaryRequests = trace.snapshot().requests.filter { $0.purpose == "compaction" && $0.dispatched == true }.count
            let result = try await store.finishCompaction(session: id, owner: owner, receipt: receipt)
            trace.record(code == "CANCELLED" ? .cancelled : .failed, code: code)
            return result
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
        let events = try await store.load(session: id)
        let repairs = Self.recovery(events)
        if !repairs.isEmpty { try await store.append(repairs, session: id) }
        // Repair the original execution log before resolving the model-only view.
        var history = try await store.loadContext(session: id).messages
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
                var compactedThisTurn = false
                for _ in 0..<maxSteps {
                    try Task.checkCancellation()
                    trace.beginRequest()
                    history += try await store.claim(session: id, owner: owner, startsTurn: false, trace: trace.identifiers())
                    latestBudget = nil; latestUsage = nil
                    var request = try await provider.prepare(messages: history, tools: tools.definitions,
                        requestID: trace.identifiers().requestID!)
                    trace.record(.measuring)
                    var budget = try await provider.measure(request, anchor: usageAnchor)
                    try Task.checkCancellation()
                    latestBudget = budget
                    trace.setBudget(budget)
                    if !compactedThisTurn, let pressure = budget.fractionUsed,
                       pressure >= compactionPolicy.pressureThreshold {
                        let snapshot = try await store.loadContext(session: id)
                        // No eligible old turns: preserve normal estimated-budget
                        // behavior; exact overflow still refuses below.
                        let eligible: Bool
                        do {
                            _ = try ContextCompactor.select(snapshot, recentTurns: compactionPolicy.recentTurns)
                            eligible = true
                        } catch CompactionError.nothingToCompact { eligible = false }
                        if eligible {
                            compactedThisTurn = true
                            trace.record(.superseded, code: "COMPACTION_REQUIRED")
                            let maintenanceTrace = DiagnosticTrace(sessionID: id) { event in
                                // The enclosing turn owns lifecycle completion. A
                                // finished summary must not finish the user's turn.
                                if ![DiagnosticStage.completed, .cancelled, .failed].contains(event.stage) {
                                    onUpdate(.diagnostic(event))
                                }
                            }
                            let result = try await performCompaction(operationID: UUID().uuidString, owner: owner, trace: maintenanceTrace, onUpdate: onUpdate)
                            if result.state == .cancelled { throw CancellationError() }
                            guard result.state == .completed else { throw CompactionFailure(receipt: result) }
                            usageAnchor = nil
                            _ = try await store.claim(session: id, owner: owner, startsTurn: false, trace: trace.identifiers())
                            history = try await store.loadContext(session: id).messages
                            trace.beginRequest()
                            request = try await provider.prepare(messages: history, tools: tools.definitions,
                                requestID: trace.identifiers().requestID!)
                            trace.record(.measuring)
                            budget = try await provider.measure(request, anchor: nil)
                            try Task.checkCancellation()
                            latestBudget = budget; trace.setBudget(budget)
                        }
                    }
                    if budget.shouldReject { throw HarnessError.contextLimit }
                    trace.record(.requesting)
                    let observer = RequestDiagnostics(trace)
                    let reply = try await provider.complete(request) { update in
                        observer.observe(update)
                        onUpdate(update)
                    }
                    try Task.checkCancellation()
                    latestUsage = reply.usage
                    trace.setUsage(reply.usage)
                    if let anchor = UsageAnchor(request: request, usage: reply.usage) { usageAnchor = anchor }
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
                    trace.record(.modelCompleted)
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
            if let message = event.modelMessage {
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
