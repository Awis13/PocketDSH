import Foundation

/// Presentation mode of the single live terminal surface.
enum TerminalPresentationMode: Equatable {
    /// Adaptive block inside the transcript feed.
    case inline
    /// Full bounds of the active pane because a full-screen TUI owns the
    /// alternate buffer.
    case expanded
}

/// Pure state for the one live terminal surface. The view owns the geometry;
/// this type only tracks which presentation is active, whether the alternate
/// buffer owns the screen and where the transcript should return to. It stays
/// free of SwiftUI/UIKit/SwiftTerm so the offline checks can exercise every
/// transition.
struct TerminalPresentation: Equatable {
    private(set) var mode: TerminalPresentationMode = .inline
    /// True while the terminal's alternate buffer owns the screen.
    private(set) var alternateBufferActive = false
    /// Shell block the transcript should scroll back to after the TUI exits.
    private(set) var anchor: String?

    var isExpanded: Bool { mode == .expanded }
    /// The user can leave the expanded surface while the TUI is still running.
    var showsReturnControl: Bool { mode == .expanded }

    /// A full-screen TUI enabled the alternate buffer (DECSET 47/1047/1049).
    mutating func alternateBufferActivated(anchor: String?) {
        alternateBufferActive = true
        mode = .expanded
        // Keep the previous anchor only when the caller has nothing better:
        // the block that owns the running TUI normally supplies one.
        self.anchor = anchor ?? self.anchor
    }

    /// The TUI released the alternate buffer (DECRST 47/1047/1049 or process
    /// exit). Returns true when this collapsed an expanded surface so the
    /// caller can restore the transcript anchor.
    @discardableResult
    mutating func alternateBufferDeactivated() -> Bool {
        alternateBufferActive = false
        let collapsed = mode == .expanded
        mode = .inline
        return collapsed
    }

    /// Leave the TUI presentation without waiting for the alternate buffer to
    /// close (the explicit "Return to transcript" control).
    mutating func returnToTranscript() {
        mode = .inline
    }

    mutating func reset() {
        self = TerminalPresentation()
    }

    /// One-shot scroll target for restoring the transcript.
    mutating func consumeAnchor() -> String? {
        defer { anchor = nil }
        return anchor
    }
}
