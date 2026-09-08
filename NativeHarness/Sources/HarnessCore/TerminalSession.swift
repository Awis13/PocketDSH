import Foundation

/// Human commands are journaled separately from model messages. Only a caller's explicit enqueue attaches a selected block to a model request.
public actor TerminalSession {
    private let store: EventStore
    private let session: String
    private let tools: WorkspaceTools
    private var task: Task<CommandBlock, any Error>?
    public init(store: EventStore, session: String, tools: WorkspaceTools) {
        self.store = store; self.session = session; self.tools = tools
    }
    public func start(command: String, onUpdate: @escaping @Sendable (LiveUpdate) -> Void = { _ in }) throws -> Task<CommandBlock, any Error> {
        guard task == nil else { throw HarnessError.busy }
        let store = store, session = session, tools = tools
        let worker = Task {
            do {
                try await store.bindWorkspace(tools.workspaceIdentity, session: session)
                let block = try await tools.runCommand(command, context: ToolExecutionContext(update: onUpdate, record: { event in
                    try await store.append([event], session: session)
                }))
                self.task = nil
                return block
            } catch {
                self.task = nil
                throw error
            }
        }
        task = worker
        return worker
    }
    public func run(command: String, onUpdate: @escaping @Sendable (LiveUpdate) -> Void = { _ in }) async throws -> CommandBlock {
        let worker = try start(command: command, onUpdate: onUpdate)
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    public func cancel() { task?.cancel() }
    public func waitUntilIdle() async { _ = try? await task?.value }
    public func blocks() async throws -> [CommandBlock] {
        try await store.load(session: session).compactMap { event in
            guard event.kind == "shell.completed", let detail = event.detail else { return nil }
            return try JSONDecoder().decode(CommandBlock.self, from: Data(detail.utf8))
        }
    }
    public func context(blockID: String) async throws -> String {
        guard let block = try await blocks().first(where: { $0.id == blockID }) else {
            throw HarnessError.invalid("Completed command block not found")
        }
        return try block.agentContext()
    }
}
