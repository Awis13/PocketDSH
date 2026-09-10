import Foundation

/// Direction of a directional pane-focus move.
enum PaneFocusDirection: CaseIterable, Equatable {
    case left, right, up, down
}

/// Pure directional focus over the split tree. Mirrors `AgentLayout` without
/// depending on SwiftUI/UIKit so the offline checks can cover it. The first
/// child of a split is always the left/top pane and the second the right/bottom
/// pane.
enum PaneFocusNavigator {
    enum Axis: Equatable { case horizontal, vertical }

    indirect enum Node: Equatable {
        case pane(String)
        case split(Axis, Node, Node)

        var panes: [String] {
            switch self {
            case .pane(let id): return [id]
            case .split(_, let first, let second): return first.panes + second.panes
            }
        }

        func contains(_ id: String) -> Bool {
            switch self {
            case .pane(let pane): return pane == id
            case .split(_, let first, let second): return first.contains(id) || second.contains(id)
            }
        }
    }

    /// The pane that receives focus when moving `direction` from `active`.
    /// Returns nil when the move leaves the workspace or `active` is absent.
    static func next(from active: String, direction: PaneFocusDirection, in tree: Node) -> String? {
        guard tree.contains(active) else { return nil }
        return descend(tree, active: active, direction: direction)
    }

    private static func descend(_ node: Node, active: String, direction: PaneFocusDirection) -> String? {
        guard case .split(let axis, let first, let second) = node else { return nil }
        switch (axis, direction) {
        case (.horizontal, .left) where second.contains(active):
            return edge(first, toward: .right)
        case (.horizontal, .right) where first.contains(active):
            return edge(second, toward: .left)
        case (.vertical, .up) where second.contains(active):
            return edge(first, toward: .down)
        case (.vertical, .down) where first.contains(active):
            return edge(second, toward: .up)
        default:
            if first.contains(active) { return descend(first, active: active, direction: direction) }
            if second.contains(active) { return descend(second, active: active, direction: direction) }
            return nil
        }
    }

    /// The pane at the far edge of a subtree in the requested direction. On a
    /// perpendicular split both children share that edge, so prefer the first
    /// child for left/up and the second for right/down to stay deterministic.
    private static func edge(_ node: Node, toward direction: PaneFocusDirection) -> String {
        switch node {
        case .pane(let id):
            return id
        case .split(let axis, let first, let second):
            switch (axis, direction) {
            case (.horizontal, .left): return edge(first, toward: .left)
            case (.horizontal, .right): return edge(second, toward: .right)
            case (.horizontal, .up): return edge(first, toward: .up)
            case (.horizontal, .down): return edge(second, toward: .down)
            case (.vertical, .up): return edge(first, toward: .up)
            case (.vertical, .down): return edge(second, toward: .down)
            case (.vertical, .left): return edge(first, toward: .left)
            case (.vertical, .right): return edge(second, toward: .right)
            }
        }
    }
}
