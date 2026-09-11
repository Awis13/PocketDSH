import Foundation
import HarnessCore

actor PTYControl {
    private var active: (id: String, session: PTYSession)?
    private let workspace: String
    let observations: TerminalObservations
    init(workspace: String, observations: TerminalObservations) { self.workspace = workspace; self.observations = observations }
    struct Event: Encodable {
        let control: String
        let ptyID: String
        var bytes: Data?
        var exit: PTYExit?
    }
    private nonisolated static func emit(_ event: Event) {
        if let data = try? JSONEncoder().encode(event) { FileHandle.standardError.write(data + Data([10])) }
    }
    func open(rows: Int, columns: Int) throws {
        guard active == nil else { throw HarnessError.busy }
        let id = UUID().uuidString
        let resolved = PTYSession.canonicalWorkspace(URL(fileURLWithPath: workspace))
        let observation = try observations.create(id: id, workspace: resolved)
        let session: PTYSession
        do { session = try PTYSession(workspace: URL(fileURLWithPath: resolved), rows: rows, columns: columns, observation: observation, segmented: true) { bytes in
            Self.emit(Event(control: "ptyOutput", ptyID: id, bytes: bytes))
        } } catch { observations.discard(id: id); throw error }
        active = (id, session)
        Self.emit(Event(control: "ptyOpened", ptyID: id))
        Task {
            let result = await session.wait()
            if active?.id == id { active = nil }
            Self.emit(Event(control: "ptyExited", ptyID: id, exit: result))
        }
    }
    private func session(_ id: String?) throws -> PTYSession {
        guard let id, let active, id == active.id else { throw HarnessError.invalid("Unknown or stale PTY ID") }
        return active.session
    }
    func input(id: String?, base64: String?) throws {
        guard let base64, base64.utf8.count <= 90000, let data = Data(base64Encoded: base64) else { throw HarnessError.invalid("Valid base64 input required") }
        try session(id).write(data)
    }
    func resize(id: String?, rows: Int, columns: Int) throws { try session(id).resize(rows: rows, columns: columns) }
    func interrupt(id: String?) throws { try session(id).interrupt() }
    func close(id: String?) throws { try session(id).close() }
    func shutdown() async {
        guard let active else { return }
        active.session.close(); _ = await active.session.wait()
    }
}
