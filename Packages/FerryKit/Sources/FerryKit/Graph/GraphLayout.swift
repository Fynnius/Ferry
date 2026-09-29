/// Lane assignment for drawing a commit graph: process newest-first, the
/// first parent continues the commit's own lane so a linear mainline stays straight,
/// freed lanes are reused so the graph doesn't widen forever, colour is per lane.
/// Commits must come children first; the order decides the width (see `GitRepository.log`
/// for why that's date order). A parent beyond the loaded page keeps its lane open to the
/// bottom, and the next page closes it: rows only depend on the commits before them, so
/// laying out a longer list never changes the rows already shown.
public struct GraphRow: Hashable, Sendable {
    public enum Anchor: Hashable, Sendable {
        /// Top edge of the row, in lane `n`.
        case top(Int)
        /// The commit's dot.
        case node
        /// Bottom edge of the row, in lane `n`.
        case bottom(Int)
    }

    public struct Segment: Hashable, Sendable {
        public var from: Anchor
        public var to: Anchor
        /// Lane whose colour the segment uses.
        public var colorLane: Int
    }

    public var commit: Commit
    /// Lane of the commit's dot.
    public var lane: Int
    public var segments: [Segment]
    /// Lanes in use in this row (for the graph column width).
    public var width: Int
}

public enum GraphLayout {
    public static func rows(for commits: [Commit]) -> [GraphRow] {
        // lanes[i] = the commit id lane i is heading down to, nil when free.
        var lanes: [String?] = []
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        for commit in commits {
            let waiting = lanes.indices.filter { lanes[$0] == commit.id }
            let lane: Int
            if let first = waiting.first {
                lane = first
            } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                lane = free
            } else {
                lane = lanes.count
                lanes.append(nil)
            }

            var segments: [GraphRow.Segment] = []
            // Everything arriving from above: lanes heading to this commit join the dot,
            // other lanes pass straight through.
            for (index, target) in lanes.enumerated() where target != nil {
                if target == commit.id {
                    segments.append(.init(from: .top(index), to: .node, colorLane: index))
                } else {
                    segments.append(.init(from: .top(index), to: .bottom(index), colorLane: index))
                }
            }
            for index in waiting where index != lane {
                lanes[index] = nil
            }

            if let firstParent = commit.parents.first {
                lanes[lane] = firstParent
                segments.append(.init(from: .node, to: .bottom(lane), colorLane: lane))
                for parent in commit.parents.dropFirst() {
                    if let existing = lanes.firstIndex(where: { $0 == parent }) {
                        segments.append(.init(from: .node, to: .bottom(existing), colorLane: existing))
                    } else {
                        let target: Int
                        if let free = lanes.indices.first(where: { lanes[$0] == nil && $0 != lane }) {
                            target = free
                        } else {
                            target = lanes.count
                            lanes.append(nil)
                        }
                        lanes[target] = parent
                        segments.append(.init(from: .node, to: .bottom(target), colorLane: target))
                    }
                }
            } else {
                lanes[lane] = nil
            }

            while lanes.last == .some(nil) { lanes.removeLast() }
            let width = max(lane + 1, segments.map { max($0.from.lane ?? 0, $0.to.lane ?? 0) + 1 }.max() ?? 1)
            rows.append(GraphRow(commit: commit, lane: lane, segments: segments, width: width))
        }
        return rows
    }
}

extension GraphRow.Anchor {
    /// The lane at the row's top or bottom edge; nil for the commit's dot.
    public var lane: Int? {
        switch self {
        case .top(let n), .bottom(let n): n
        case .node: nil
        }
    }
}
