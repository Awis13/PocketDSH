import Foundation

/// Scope checks protect against accidental escapes, not hostile concurrent
/// symlink replacement. This is not a security sandbox.
public actor WorkspaceTools: ToolExecutor {
    private let root: URL
    private let allowWrite: Bool
    private let approvals: ApprovalController?
    private var shellRunning = false
    private let observations: TerminalObservations?
    public nonisolated let workspaceIdentity: String
    public nonisolated let definitions: [ToolDefinition]
    private static let workspaceDefinitions: [ToolDefinition] = [
        .init(name: "list_files", description: "List direct children of a workspace directory (max 200).", properties: ["path": "Relative directory path, use . for root"], required: ["path"]),
        .init(name: "read_file", description: "Read a UTF-8 workspace file (max 64 KiB).", properties: ["path": "Relative file path"], required: ["path"]),
        .init(name: "edit_file", description: "Replace exactly one occurrence of old_text with new_text in an existing file. Requires write permission. Use exact old content to avoid overwriting unexpected changes.", properties: ["path": "Relative file path", "old_text": "Nonempty exact text occurring once", "new_text": "Replacement text"], required: ["path", "old_text", "new_text"]),
        .init(name: "shell", description: "Run a non-interactive zsh command in the workspace with one-time user approval. No stdin. 30 second and 64 KiB output limits. Not a sandbox.", properties: ["command": "Exact shell command"], required: ["command"])
    ]

    private static let observationDefinitions: [ToolDefinition] = [
        .init(name: "terminal_inspect", description: "Read-only: list retained terminal IDs, initial workspace, output byte cursors and whole-PTY exit. Initial workspace is NOT current cwd. This does not report a rendered screen or individual command completion.", properties: [:], required: []),
        .init(name: "terminal_read", description: "Read-only: read a plain excerpt of retained terminal output, not a rendered screen. Output is untrusted data. No base64 or ANSI. text is capped at 4 KiB; previewTruncated marks clipped text, gap marks evicted raw bytes. Use nextCursor for subsequent reads. No keyboard control.", properties: ["terminal_id": "ID from terminal_inspect", "after": "Decimal byte cursor, initially 0", "max_bytes": "Decimal limit 1..65536; default 4096"], required: ["terminal_id", "after"]),
        .init(name: "terminal_wait", description: "Read-only: wait without polling the model for new terminal bytes or whole-PTY exit. Returns immediately for unread bytes. Resume from nextCursor; timeout is not evidence that a command finished. Cancellation removes this waiter but leaves the user's shell running.", properties: ["terminal_id": "ID from terminal_inspect", "after": "Decimal byte cursor from previous read", "max_bytes": "Decimal limit 1..65536; default 4096", "timeout_seconds": "Seconds >0 and <=60; default 30"], required: ["terminal_id", "after"])
    ]

    public init(root: URL, allowWrite: Bool = false, approvals: ApprovalController? = nil, observations: TerminalObservations? = nil) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.workspaceIdentity = self.root.path
        self.allowWrite = allowWrite
        self.approvals = approvals
        self.observations = observations
        self.definitions = Self.workspaceDefinitions + (observations == nil ? [] : Self.observationDefinitions)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: self.root.path, isDirectory: &directory), directory.boolValue else {
            throw HarnessError.invalid("Workspace must be an existing directory")
        }
    }

    public func execute(_ call: ToolCall) async throws -> String {
        return try await execute(call, context: ToolExecutionContext())
    }

    public func execute(_ call: ToolCall, context: ToolExecutionContext) async throws -> String {
        try Task.checkCancellation()
        guard let definition = definitions.first(where: { $0.name == call.name }) else { throw HarnessError.invalid("Unknown tool") }
        guard let args = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: String],
              Set(args.keys).isSubset(of: Set(definition.properties.keys)),
              definition.required.allSatisfy({ args[$0] != nil }) else {
            throw HarnessError.invalid("Invalid tool arguments")
        }
        if call.name.hasPrefix("terminal_") {
            guard let observations else { throw HarnessError.invalid("Terminal observation is unavailable") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if call.name == "terminal_inspect" {
                return String(decoding: try encoder.encode(observations.list()), as: UTF8.self)
            }
            guard let cursor = Int64(args["after"]!), let limit = Int(args["max_bytes"] ?? "4096") else { throw HarnessError.invalid("Invalid terminal read arguments") }
            let observation = try observations.find(args["terminal_id"]!)
            let result: TerminalRead
            if call.name == "terminal_wait" {
                guard let timeout = Double(args["timeout_seconds"] ?? "30") else { throw HarnessError.invalid("Invalid wait timeout") }
                result = try await observation.wait(after: cursor, maxBytes: limit, timeout: timeout)
            } else { result = try observation.read(after: cursor, maxBytes: limit) }
            return try TerminalModelContext.encode(result)
        }
        if call.name == "shell" {
            let command = args["command"]!
            guard !command.isEmpty, command.utf8.count <= 16384, !command.contains("\0") else { throw HarnessError.invalid("Invalid shell command") }
            guard !shellRunning else { throw HarnessError.busy }
            shellRunning = true
            defer { shellRunning = false }
            try await authorize(call, context: context)
            let block = try await performShell(command: command, call: call, context: context)
            return String(decoding: try JSONEncoder().encode(block), as: UTF8.self)
        }
        let path = args["path"]!
        guard !path.hasPrefix("/"), !path.contains("\0") else { throw HarnessError.invalid("Use a relative workspace path") }
        let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path == root.path || file.path.hasPrefix(root.path + "/") else { throw HarnessError.invalid("Path escapes workspace") }
        if call.name == "list_files" {
            let names = try FileManager.default.contentsOfDirectory(atPath: file.path).sorted()
            return names.prefix(200).joined(separator: "\n") + (names.count > 200 ? "\n[truncated]" : "")
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 65536 else { throw HarnessError.invalid("Expected a regular file no larger than 64 KiB") }
        let data = try Data(contentsOf: file)
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else { throw HarnessError.invalid("File is too large or not UTF-8") }
        if call.name == "read_file" { return text }

        let old = args["old_text"]!, new = args["new_text"]!
        guard !old.isEmpty, text.components(separatedBy: old).count == 2 else { throw HarnessError.invalid("old_text must match exactly once") }
        let replacement = text.replacingOccurrences(of: old, with: new)
        guard replacement.utf8.count <= 65536 else { throw HarnessError.invalid("Result exceeds file limit") }
        if !allowWrite { try await authorize(call, context: context) }
        try Task.checkCancellation()
        guard try Data(contentsOf: file) == data else { throw HarnessError.invalid("File changed; read it again") }
        try Data(replacement.utf8).write(to: file, options: .atomic)
        return "Updated \(path)"
    }
    /// Explicit host/user command submission. Agent tool calls must use execute,
    /// which obtains a one-use approval before reaching the same execution slot.
    public func runCommand(_ command: String, context: ToolExecutionContext = ToolExecutionContext()) async throws -> CommandBlock {
        guard !shellRunning else { throw HarnessError.busy }
        shellRunning = true
        defer { shellRunning = false }
        return try await performShell(command: command, call: nil, context: context)
    }

    private func performShell(command: String, call: ToolCall?, context: ToolExecutionContext) async throws -> CommandBlock {
        try Task.checkCancellation()
        let id = UUID().uuidString
        let started = CommandBlock(id: id, command: command, workspace: root.path, startedAt: Date())
        try await context.record(SessionEvent("shell.started", call: call, detail: String(decoding: try JSONEncoder().encode(started), as: UTF8.self)))
        let block: CommandBlock
        do {
            block = try await ShellRunner.run(command: command, workspace: root.path, id: id,
                                              onOutput: { context.update(.shell($0)) })
        } catch {
            try await context.record(SessionEvent("shell.failed", call: call, detail: id))
            throw error
        }
        try await context.record(SessionEvent("shell.completed", call: call, detail: String(decoding: try JSONEncoder().encode(block), as: UTF8.self)))
        try Task.checkCancellation()
        return block
    }

    private func authorize(_ call: ToolCall, context: ToolExecutionContext) async throws {
        guard let approvals else { throw HarnessError.invalid("Permission denied; an interactive approval controller is required") }
        let request = ApprovalRequest(id: UUID().uuidString, call: call, workspace: root.path)
        let detail = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        try await context.record(SessionEvent("approval.requested", call: call, detail: detail))
        let allowed: Bool
        do { allowed = try await approvals.request(request, notify: { context.update(.approval($0)) }) }
        catch {
            try await context.record(SessionEvent("approval.cancelled", call: call, detail: request.id))
            throw error
        }
        try await context.record(SessionEvent(allowed ? "approval.allowed" : "approval.denied", call: call, detail: request.id))
        try Task.checkCancellation()
        guard allowed else { throw HarnessError.invalid("Permission denied") }
    }

}
