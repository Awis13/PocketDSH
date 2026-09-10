import Foundation
import Darwin
import HarnessCore

/// A real terminal supplies rendering and keyboard encoding. No emulation or
/// escape-sequence parsing is hidden inside the agent's chat renderer.
enum TerminalForwarder {
    static func run(workspace: String) async throws -> PTYExit {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw HarnessError.invalid("--terminal needs an interactive terminal on stdin and stdout")
        }
        var saved = termios()
        guard tcgetattr(STDIN_FILENO, &saved) == 0 else { throw HarnessError.invalid("Cannot read terminal attributes") }
        var size = winsize()
        _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)
        let terminal = try PTYSession(workspace: URL(fileURLWithPath: workspace), rows: max(1, Int(size.ws_row)), columns: max(1, Int(size.ws_col))) {
            FileHandle.standardOutput.write($0)
        }
        var raw = saved; cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            terminal.close(); _ = await terminal.wait(); throw HarnessError.invalid("Cannot enter terminal raw mode")
        }
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        resize.setEventHandler(handler: { @Sendable in
            var size = winsize()
            if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 {
                try? terminal.resize(rows: max(1, Int(size.ws_row)), columns: max(1, Int(size.ws_col)))
            }
        })
        resize.resume()
        let oldInt = signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler(handler: { @Sendable in try? terminal.interrupt() }); interrupt.resume()
        let oldTerm = signal(SIGTERM, SIG_IGN)
        let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        stop.setEventHandler(handler: { @Sendable in terminal.close() }); stop.resume()
        defer { resize.cancel(); stop.cancel(); interrupt.cancel(); signal(SIGTERM, oldTerm); signal(SIGINT, oldInt) }
        let reader = Task.detached {
            while !Task.isCancelled {
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 20) > 0 {
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = read(STDIN_FILENO, &bytes, bytes.count)
                    guard count > 0 else { terminal.close(); break }
                    do { try terminal.write(Data(bytes.prefix(count))) }
                    catch { terminal.close(); break }
                }
            }
        }
        let result = await withTaskCancellationHandler { await terminal.wait() } onCancel: { terminal.close() }
        reader.cancel(); await reader.value
        return result
    }
}
