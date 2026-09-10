import Foundation
import HarnessCore

/// Pure projection from the durable inbox to the wire snapshot. Bounds both the
/// item count and each preview so a large queue stays well inside the
/// presentation budget. Kept separate from the socket so it is unit-testable.
enum NativeQueueProjection {
    static let itemLimit = 64
    static let previewLimit = 512

    static func snapshot(_ commands: [PendingCommand], limit: Int = itemLimit,
                         previewLimit: Int = previewLimit) -> NativeQueueInfo {
        let shown = commands.prefix(max(0, limit)).map { item($0, previewLimit: previewLimit) }
        return NativeQueueInfo(items: shown, omitted: max(0, commands.count - shown.count))
    }

    static func item(_ command: PendingCommand, previewLimit: Int = previewLimit) -> NativeQueueItem {
        let (preview, clipped) = clip(command.prompt, bytes: previewLimit)
        return NativeQueueItem(id: command.id, preview: preview,
            placement: command.mode == .steer ? NativeQueueItem.steering : NativeQueueItem.queued,
            truncated: clipped)
    }

    private static func clip(_ text: String, bytes: Int) -> (String, Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > bytes { break }
            result.append(character); used += size
        }
        return (result, true)
    }
}
