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

    /// Builds a split node from the layout's stacked flag. Kept here so the
    /// vertical/horizontal mapping is compiled and asserted by the offline
    /// checks instead of only living in the SwiftUI `AgentLayout` mirror.
    static func node(stacked: Bool, first: Node, second: Node) -> Node {
        .split(stacked ? .vertical : .horizontal, first, second)
    }

    /// The pane that receives focus when moving `direction` from `active`.
    /// Returns nil when the move leaves the workspace or `active` is absent.
    static func next(from active: String, direction: PaneFocusDirection, in tree: Node) -> String? {
        guard tree.contains(active) else { return nil }
        let perpendicular = perpendicularAxis(direction)
        guard let activePerpendicular = coordinate(of: active, along: perpendicular, in: tree) else { return nil }
        return descend(tree, active: active, direction: direction, range: 0...1, activePerpendicular: activePerpendicular)
    }

    private static func movementAxis(_ direction: PaneFocusDirection) -> Axis {
        direction == .left || direction == .right ? .horizontal : .vertical
    }

    private static func perpendicularAxis(_ direction: PaneFocusDirection) -> Axis {
        movementAxis(direction) == .horizontal ? .vertical : .horizontal
    }

    private static func opposite(_ direction: PaneFocusDirection) -> PaneFocusDirection {
        switch direction {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }

    /// Normalized center of `active` along one axis, assuming equal child
    /// splits. Splits along the other axis leave the coordinate unchanged.
    private static func coordinate(of active: String, along axis: Axis, in node: Node) -> Double? {
        switch node {
        case .pane(let id):
            return id == active ? 0.5 : nil
        case .split(let splitAxis, let first, let second):
            if splitAxis == axis {
                if let value = coordinate(of: active, along: axis, in: first) { return value * 0.5 }
                if let value = coordinate(of: active, along: axis, in: second) { return 0.5 + value * 0.5 }
                return nil
            }
            return coordinate(of: active, along: axis, in: first) ?? coordinate(of: active, along: axis, in: second)
        }
    }

    private static func descend(_ node: Node, active: String, direction: PaneFocusDirection, range: ClosedRange<Double>, activePerpendicular: Double) -> String? {
        guard case .split(let axis, let first, let second) = node else { return nil }
        if axis == movementAxis(direction) {
            // The move crosses this split when `active` sits on its far side.
            let crosses = (direction == .left || direction == .up) ? second.contains(active) : first.contains(active)
            if crosses {
                let target = (direction == .left || direction == .up) ? first : second
                return edge(target, toward: opposite(direction), range: range, activePerpendicular: activePerpendicular)
            }
            // Otherwise keep descending toward `active`; a parallel split does
            // not change the perpendicular coordinate.
            if first.contains(active) { return descend(first, active: active, direction: direction, range: range, activePerpendicular: activePerpendicular) }
            if second.contains(active) { return descend(second, active: active, direction: direction, range: range, activePerpendicular: activePerpendicular) }
            return nil
        }
        // Perpendicular split: narrow the active pane's row/column range so the
        // entering edge can pick the nearest pane.
        let mid = (range.lowerBound + range.upperBound) / 2
        if first.contains(active) { return descend(first, active: active, direction: direction, range: range.lowerBound...mid, activePerpendicular: activePerpendicular) }
        if second.contains(active) { return descend(second, active: active, direction: direction, range: mid...range.upperBound, activePerpendicular: activePerpendicular) }
        return nil
    }

    /// The pane at the far edge of a subtree in the requested direction. On a
    /// perpendicular split both children share that edge, so choose the child
    /// nearest the active pane's perpendicular coordinate; when `active` is
    /// exactly on the boundary, fall back to the first/second tie-break.
    private static func edge(_ node: Node, toward direction: PaneFocusDirection, range: ClosedRange<Double>, activePerpendicular: Double) -> String {
        switch node {
        case .pane(let id):
            return id
        case .split(let axis, let first, let second):
            let mid = (range.lowerBound + range.upperBound) / 2
            let firstRange = range.lowerBound...mid
            let secondRange = mid...range.upperBound
            if axis == perpendicularAxis(direction) {
                if activePerpendicular < mid {
                    return edge(first, toward: direction, range: firstRange, activePerpendicular: activePerpendicular)
                }
                if activePerpendicular > mid {
                    return edge(second, toward: direction, range: secondRange, activePerpendicular: activePerpendicular)
                }
            }
            let chooseFirst = direction == .left || direction == .up
            return chooseFirst
                ? edge(first, toward: direction, range: axis == perpendicularAxis(direction) ? firstRange : range, activePerpendicular: activePerpendicular)
                : edge(second, toward: direction, range: axis == perpendicularAxis(direction) ? secondRange : range, activePerpendicular: activePerpendicular)
        }
    }
}
