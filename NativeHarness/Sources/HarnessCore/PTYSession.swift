import Foundation
import Darwin
import CPTY

public struct PTYExit: Codable, Sendable {
    public let code: Int32?
    public let signal: Int32?
    public let closedByHost: Bool
}

/// Persistent interactive shell. The byte stream contains terminal escape
/// sequences, not plain text. Render with a terminal emulator, never a chat label.
public final class PTYSession: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var fd: Int32
        let pid: pid_t
        var input = Data()
        var closing = false
        var promptReady = false
        init(fd: Int32, pid: pid_t) { self.fd = fd; self.pid = pid }
    }
    private let state: State
    private let worker: Task<PTYExit, Never>
    private let integration: ShellIntegration?

    public init(workspace: URL, rows: Int = 24, columns: Int = 80,
                observation: TerminalObservation? = nil,
                segmented: Bool = false,
                onFrame: @escaping @Sendable (ShellFrame) -> Void = { _ in },
                onOutput: @escaping @Sendable (Data) -> Void) throws {
        try Self.validateSize(rows, columns)
        let path = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard !path.contains("\0"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            throw HarnessError.invalid("PTY workspace must be a directory")
        }
        let integration = try segmented ? ShellIntegration() : nil
        self.integration = integration
        let argv = ["/bin/zsh", segmented ? "-d" : "-f", "-i"].map { $0.withCString { strdup($0) } } + [nil]
        let env = ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(NSHomeDirectory())", "LANG=en_US.UTF-8", "TERM=xterm-256color"] + (integration.map { ["ZDOTDIR=\($0.directory.path)"] } ?? [])
        let environmentStrings = env
        let environmentPointers = environmentStrings.map { $0.withCString { strdup($0) } } + [nil]
        defer { for value in argv + environmentPointers { free(value) } }
        var fd: Int32 = -1
        let pid = path.withCString { cwd in argv.withUnsafeBufferPointer { args in environmentPointers.withUnsafeBufferPointer { environment in
            harness_open_pty(&fd, cwd, args.baseAddress!, environment.baseAddress!, UInt16(rows), UInt16(columns))
        } } }
        guard pid > 0 else { throw HarnessError.invalid("Cannot create PTY") }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1, fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else {
            Darwin.close(fd); kill(pid, SIGKILL); var status: Int32 = 0; _ = waitpid(pid, &status, 0)
            throw HarnessError.invalid("Cannot configure PTY")
        }
        let state = State(fd: fd, pid: pid)
        self.state = state
        self.worker = Task.detached { [integration] in
            var parser = ShellFrameParser(nonce: integration?.nonce ?? "")
            func deliver(_ frame: ShellFrame) {
                if case .completion(let id, let values, let limited) = frame {
                    integration?.resolve(id: id, values: values, limited: limited); return
                }
                if case .ready(let code, let directory) = frame {
                    state.lock.withLock { state.promptReady = true }
                    observation?.recordReady(code: code, directory: directory)
                }
                if case .start(let command, let directory) = frame {
                    state.lock.withLock { state.promptReady = false }
                    observation?.recordStart(command: command, directory: directory)
                }
                if case .output(let bytes) = frame { observation?.append(bytes); onOutput(bytes) }
                onFrame(frame)
            }
            let result = Self.pump(state, onOutput: { data in
                if integration != nil { for frame in parser.feed(data) { deliver(frame) } }
                else { observation?.append(data); onOutput(data) }
            })
            if integration != nil { for frame in parser.finish() { deliver(frame) } }
            observation?.finish(result)
            return result
        }
    }

    deinit { close() }

    /// Queue input atomically; reject rather than dropping bytes on overload.
    public func write(_ bytes: Data) throws {
        state.lock.lock(); defer { state.lock.unlock() }
        guard state.fd >= 0, !state.closing else { throw HarnessError.invalid("PTY is closed") }
        guard bytes.count <= 65536 - state.input.count else { throw HarnessError.invalid("PTY input queue is full") }
        state.promptReady = false
        state.input.append(bytes)
    }
    /// Completion is an out-of-band lookup at an idle prompt, not shell input.
    public func complete(token: String, kind: String) async throws -> ShellCompletions {
        guard let integration, ["command", "path", "directory"].contains(kind), token.utf8.count <= 4096,
              !token.contains("\0"), !token.contains("\n") else { throw HarnessError.invalid("Invalid completion request") }
        let id = try state.lock.withLock {
            guard state.fd >= 0, !state.closing, state.promptReady, state.input.isEmpty else {
                throw HarnessError.invalid("Completion is available at an idle shell prompt")
            }
            let id = try integration.beginCompletion(token: token, kind: kind)
            state.input.append(integration.completionKey)
            return id
        }
        defer { integration.cancel(id: id) }
        for _ in 0..<100 {
            if let result = integration.result(id: id) { return result }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HarnessError.invalid("Shell completion timed out")
    }
    /// An explicit user interrupt must also work when a TUI disables ISIG.
    /// Resolve the foreground group now; never signal a cached job/PID later.
    public func interrupt() throws {
        state.lock.lock(); defer { state.lock.unlock() }
        guard state.fd >= 0, !state.closing else { throw HarnessError.invalid("PTY is closed") }
        let foreground = tcgetpgrp(state.fd)
        guard foreground > 0 else { throw HarnessError.invalid("No foreground terminal process") }
        if foreground == state.pid {
            guard state.input.count < 65536 else { throw HarnessError.invalid("PTY input queue is full") }
            state.input.append(3) // Cancel an unfinished shell line without killing zsh.
        } else if kill(-foreground, SIGINT) != 0 && errno != ESRCH {
            throw HarnessError.invalid("Cannot interrupt foreground command")
        }
    }
    public func resize(rows: Int, columns: Int) throws {
        try Self.validateSize(rows, columns)
        state.lock.lock(); defer { state.lock.unlock() }
        guard state.fd >= 0, !state.closing else { throw HarnessError.invalid("PTY is closed") }
        guard harness_resize_pty(state.fd, UInt16(rows), UInt16(columns)) == 0 else { throw HarnessError.invalid("PTY resize failed") }
    }
    public func close() {
        state.lock.lock(); state.closing = true; state.lock.unlock()
    }
    public func wait() async -> PTYExit { await worker.value }
    private static func validateSize(_ rows: Int, _ columns: Int) throws {
        guard (1...1000).contains(rows), (1...1000).contains(columns) else { throw HarnessError.invalid("Invalid terminal size") }
    }
    private static func pump(_ state: State, onOutput: (Data) -> Void) -> PTYExit {
        let clock = ContinuousClock()
        var stopping: ContinuousClock.Instant?
        var result = PTYExit(code: nil, signal: nil, closedByHost: false)
        var exited = false
        while true {
            state.lock.lock()
            let fd = state.fd
            let closing = state.closing
            if !state.input.isEmpty && !closing {
                let written = state.input.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if written > 0 { state.input.removeFirst(written) }
                else if written < 0 && errno != EAGAIN && errno != EINTR { state.closing = true }
            }
            state.lock.unlock()
            if closing && stopping == nil {
                stopping = clock.now
                // Foreground jobs have their own group. Signal it once while it
                // owns this terminal; never cache that PGID for a delayed kill.
                let foreground = tcgetpgrp(fd)
                if foreground > 0 && foreground != state.pid { kill(-foreground, SIGHUP) }
                kill(-state.pid, SIGHUP)
            }
            var eof = false
            for _ in 0..<16 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &bytes, bytes.count)
                if count > 0 { onOutput(Data(bytes.prefix(count))) }
                else {
                    eof = count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)
                    break
                }
            }
            var info = siginfo_t()
            let observed = waitid(P_PID, id_t(state.pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if observed == 0 && info.si_pid == state.pid {
                exited = true
                result = PTYExit(code: info.si_code == CLD_EXITED ? info.si_status : nil,
                                 signal: info.si_code == CLD_EXITED ? nil : info.si_status, closedByHost: stopping != nil)
                if stopping == nil { stopping = clock.now }
            }
            if observed == -1 && errno != EINTR { break }
            if let stopping, stopping.duration(to: clock.now) >= .milliseconds(300) {
                kill(-state.pid, SIGKILL)
                if exited { break }
            }
            if exited && eof { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if eof { descriptor.fd = -1 }
            _ = poll(&descriptor, 1, 15)
        }
        state.lock.lock()
        Darwin.close(state.fd); state.fd = -1; state.closing = true; state.input.removeAll()
        state.lock.unlock()
        // Unreaped leader retains its PID while its group is cleaned up.
        if exited { kill(-state.pid, SIGKILL) }
        var status: Int32 = 0
        while waitpid(state.pid, &status, 0) == -1 && errno == EINTR {}
        return result
    }
}
