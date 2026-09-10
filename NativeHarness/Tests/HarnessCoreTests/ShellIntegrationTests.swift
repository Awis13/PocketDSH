import XCTest
@testable import HarnessCore

final class ShellIntegrationTests: XCTestCase {
    func testInteractiveListingsPreserveArgumentsAndPlatformFallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("eza"), calls = root.appendingPathComponent("calls")
        try Data("#!/bin/sh\nprintf '%s\\0' \"$@\" > calls\nexit \"${FIXTURE_EXIT:-0}\"\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let events = FrameCapture()
        let pty = try PTYSession(workspace: root, segmented: true, onFrame: { events.add($0) }, onOutput: { _ in })
        defer { pty.close() }
        try await events.waitForReady(count: 1)
        var ready = 1
        func run(_ command: String) async throws {
            try pty.write(Data((command + "\r").utf8))
            ready += 1; try await events.waitForReady(count: ready)
        }
        func args() throws -> [String] { String(decoding: try Data(contentsOf: calls), as: UTF8.self).split(separator: "\0").map(String.init) }
        try await run("export PATH=\"$PWD:$PATH\"; ls -lah -- 'path with spaces' '$(touch SHOULD_NOT_EXIST)'")
        XCTAssertEqual(try args(), ["--color=auto", "--icons=auto", "--group-directories-first", "-l", "-a", "--header", "--git", "--", "path with spaces", "$(touch SHOULD_NOT_EXIST)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
        try await run("lt --level=3 -- 'path with spaces'")
        XCTAssertEqual(try args().suffix(5), ["--tree", "--level=2", "--level=3", "--", "path with spaces"])
        try await run("la --no-icons")
        XCTAssertTrue(try args().contains("--all"))
        try await run("export FIXTURE_EXIT=7; ll")
        XCTAssertTrue(events.read().contains { if case .ready(let code, _) = $0 { code == 7 } else { false } })
        for command in ["ls | cat", "ls > listing.txt", "ls -t", "HARNESS_EZA=0 ls", "command ls"] {
            try FileManager.default.removeItem(at: calls)
            try await run(command)
            XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path), "Platform ls expected: \(command)")
            // Recreate only the sentinel; a subsequent eza invocation overwrites it.
            try Data().write(to: calls)
        }
        try FileManager.default.removeItem(at: calls)
        try await run("PATH=/usr/bin:/bin; ls; ll; la; lt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path), "eza is optional on the host")
        pty.close(); _ = await pty.wait()
    }

    func testEveryByteBoundaryAndANSI() {
        let marker = "\u{1b}P+h;n;S;" + Data("printf hi".utf8).base64EncodedString() + ";" + Data("/tmp".utf8).base64EncodedString() + "\u{1b}\\"
        let bytes = Data(("before" + marker + "\u{1b}[31mhi\rthere").utf8)
        for split in 0...bytes.count {
            var parser = ShellFrameParser(nonce: "n")
            let frames = parser.feed(bytes.prefix(split)) + parser.feed(bytes.suffix(bytes.count - split)) + parser.finish()
            XCTAssertEqual(frames.filter { if case .start = $0 { true } else { false } }, [.start(command: "printf hi", directory: "/tmp")])
            let output = frames.reduce(into: Data()) { if case .output(let data) = $1 { $0.append(data) } }
            XCTAssertEqual(output, Data("before\u{1b}[31mhi\rthere".utf8))
        }
    }
    func testMalformedAndForeignMarkersRemainOutput() {
        var parser = ShellFrameParser(nonce: "ours")
        let data = Data("\u{1b}P+h;foreign;E;0;Lw==\u{1b}\\\u{1b}P+h;ours;S;invalid;Lw==\u{1b}\\".utf8)
        let output = (parser.feed(data) + parser.finish()).reduce(into: Data()) { if case .output(let bytes) = $1 { $0.append(bytes) } }
        XCTAssertEqual(output, data)
    }
    func testPersistentShellLifecycle() async throws {
        let events = FrameCapture()
        let pty = try PTYSession(workspace: URL(fileURLWithPath: "/tmp"), segmented: true, onFrame: { events.add($0) }, onOutput: { _ in })
        defer { pty.close() }
        try await events.waitForReady(count: 1)
        try pty.write(Data("export HARNESS_BLOCK_TEST=kept; cd /\r".utf8))
        try await events.waitForReady(count: 2)
        try pty.write(Data("printf '%s' \"$HARNESS_BLOCK_TEST\"; false\r".utf8))
        try await events.waitForReady(count: 3)
        let frames = events.read()
        XCTAssertTrue(frames.contains(.ready(code: 1, directory: "/")))
        XCTAssertTrue(frames.contains { if case .start(let command, let cwd) = $0 { return command.contains("printf") && cwd == "/" }; return false })
        let output = frames.reduce(into: Data()) { if case .output(let bytes) = $1 { $0.append(bytes) } }
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("kept"))
        pty.close(); _ = await pty.wait()
    }
    func testCompletionUsesPersistentShellWithoutExecutingDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("My Folder"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("My File.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let events = FrameCapture()
        let pty = try PTYSession(workspace: root, segmented: true, onFrame: { events.add($0) }, onOutput: { _ in })
        defer { pty.close() }
        try await events.waitForReady(count: 1)
        let commands = try await pty.complete(token: "prin", kind: "command")
        XCTAssertTrue(commands.values.contains("printf"))
        let all = try await pty.complete(token: "", kind: "command")
        XCTAssertTrue(all.limited && all.values.count <= 100)
        let paths = try await pty.complete(token: "My F", kind: "path")
        XCTAssertEqual(paths.values, ["My File.txt", "My Folder/"])
        let dirs = try await pty.complete(token: "My", kind: "directory")
        XCTAssertEqual(dirs.values, ["My Folder/"])
        try pty.write(Data("alias fixturecmd='printf alias'; export FIXTURE_DIR=\"$PWD\"; cd 'My Folder'\r".utf8))
        try await events.waitForReady(count: 2)
        let alias = try await pty.complete(token: "fixturec", kind: "command")
        XCTAssertEqual(alias.values, ["fixturecmd"])
        let relative = try await pty.complete(token: "../My", kind: "path")
        XCTAssertEqual(relative.values, ["../My File.txt", "../My Folder/"])
        let variable = try await pty.complete(token: "$FIXTURE_DIR/My", kind: "path")
        XCTAssertEqual(variable.values, ["$FIXTURE_DIR/My File.txt", "$FIXTURE_DIR/My Folder/"])
        let injection = try await pty.complete(token: "$(touch SHOULD_NOT_EXIST)", kind: "path")
        XCTAssertTrue(injection.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("My Folder/SHOULD_NOT_EXIST").path))
        XCTAssertEqual(events.read().filter { if case .start = $0 { true } else { false } }.count, 1, "Tab must not create command blocks")
        try pty.write(Data("printf 'AFTER_COMPLETION\\n'\r".utf8))
        try await events.waitForReady(count: 3)
        let lastStart = events.read().last { if case .start = $0 { true } else { false } }
        guard case .start(let command, let cwd) = lastStart else { return XCTFail("Missing command after completion") }
        XCTAssertEqual(command, "printf 'AFTER_COMPLETION\\n'")
        XCTAssertTrue(cwd.hasSuffix("/\(root.lastPathComponent)/My Folder")) // /var and /private/var are the same macOS temp directory.
        try pty.write(Data("sleep 5\r".utf8))
        do { _ = try await pty.complete(token: "prin", kind: "command"); XCTFail("Completion must not write into a running program") }
        catch { XCTAssertTrue(String(describing: error).contains("idle shell prompt")) }
        try pty.interrupt()
        pty.close(); _ = await pty.wait()
    }
    func testSegmentedShellRecordsCommandLifecycleInObservation() async throws {
        let history = try TerminalObservation(id: "lifecycle", initialWorkspace: "/tmp")
        let pty = try PTYSession(workspace: FileManager.default.temporaryDirectory, observation: history, segmented: true, onOutput: { _ in })
        defer { pty.close() }
        try pty.write(Data("cd /; printf 'LIFECYCLE\\n'; false\r".utf8))
        var record: TerminalCommand?
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            record = history.commandHistory(limit: 16).last { $0.command?.contains("LIFECYCLE") == true && $0.endedAt != nil }
            if record != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let finished = try XCTUnwrap(record)
        XCTAssertEqual(finished.exitCode, 1)
        XCTAssertEqual(finished.directory, "/")
        XCTAssertNotNil(finished.startedAt); XCTAssertNotNil(finished.endedAt)
        XCTAssertTrue(history.commandHistory(limit: 16).contains { $0.command == nil && $0.exitCode == 0 })
        pty.close(); _ = await pty.wait()
    }
}
private final class FrameCapture: @unchecked Sendable {
    let lock = NSLock()
    var frames: [ShellFrame] = []
    func add(_ frame: ShellFrame) { lock.lock(); frames.append(frame); lock.unlock() }
    func read() -> [ShellFrame] { lock.lock(); defer { lock.unlock() }; return frames }
    func waitForReady(count: Int) async throws {
        for _ in 0..<150 {
            if read().filter({ if case .ready = $0 { true } else { false } }).count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HarnessError.invalid("Shell lifecycle timed out: \(read())")
    }
}
