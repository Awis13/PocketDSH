import Foundation

enum NativeRecovery {
    static func unfinishedCompactions(_ history: [NativeEvent]) -> [NativeCompactionInfo] {
        var latest: [String: NativeCompactionInfo] = [:]
        for event in history where event.op == "compaction" {
            if let receipt = event.compaction { latest[receipt.id] = receipt }
        }
        return latest.values.filter(\.isRunning).sorted { $0.id < $1.id }
    }
    /// The core receipt is authoritative when commit preceded UI publication.
    static func compactionEvent(_ previous: NativeCompactionInfo, stored: NativeCompactionInfo?, session: String) -> NativeEvent {
        NativeEvent(op: "compaction", session: session, id: previous.id,
            compaction: stored ?? NativeCompactionInfo(id: previous.id, state: "interrupted", code: "COMPACTION_INTERRUPTED"))
    }
    /// Repairs only unfinished work. Repeated recovery is idempotent; it never
    /// invents an exit code or a successful result for an interrupted command.
    static func events(_ history: [NativeEvent], session: String, engineInterrupted: Bool, pendingCount: Int) -> [NativeEvent] {
        var block: NativeEvent?
        var tools: [NativeEvent] = []
        var active = false
        var request: NativeRequestInfo?
        for event in history {
            if event.op == "stage", let latest = event.request, latest.validIdentity { request = latest }
            switch event.op {
            case "blockStart": block = event
            case "blockEnd": block = nil
            case "user", "text", "reasoning": active = true
            case "toolCall": tools.append(event); active = true
            case "toolResult": tools.removeAll { $0.id == event.id }
            case "stage": active = !["completed", "cancelled", "failed", "interrupted"].contains(event.stage ?? "")
            default: break
            }
        }
        var result: [NativeEvent] = []
        if let block {
            result.append(NativeEvent(op: "blockEnd", session: session, text: "Interrupted — exit status unknown", workspace: block.workspace, failed: true))
        }
        for tool in tools {
            result.append(NativeEvent(op: "toolResult", session: session, id: tool.id,
                text: "Interrupted. Outcome unknown; verify external state before retrying.", failed: true))
        }
        if request?.isFinished == false { request?.interrupt() }
        if active || engineInterrupted || pendingCount > 0 || !tools.isEmpty {
            let queued = pendingCount > 0
                ? " \(pendingCount) queued request\(pendingCount == 1 ? "" : "s") preserved; resume explicitly to run."
                : " Send a new request to continue."
            result.append(NativeEvent(op: "stage", session: session,
                text: "Host restarted. Unfinished work was interrupted; queued requests were not run." + queued, stage: "interrupted", request: request))
        }
        return result
    }
}
