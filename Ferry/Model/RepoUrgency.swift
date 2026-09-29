import SwiftUI
import FerryKit

/// What a repo needs from the user next, most urgent first. One vocabulary for the
/// stack's order and groups, the menu bar, the Dock menu and the status colours.
enum RepoUrgency: Int, Comparable, CaseIterable {
    /// Conflicts, a merge/rebase left in progress, or a failed operation.
    case problem
    /// Uncommitted work someone touched recently: where the writing happens, so first.
    case changes
    /// Nothing to commit, commits to push (push = deploy): one click finishes it.
    case readyToPush
    /// A branch with commits that isn't on the remote (yet, or any more).
    case unpublished
    /// Only needs a pull. Shown as "Updates available", not as needing you.
    case behind
    /// Uncommitted changes nobody touched for `RepoItem.dormantAfter`.
    case dormant
    case clear

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Counts toward Needs Attention, the badges and "next repo".
    var needsYou: Bool { self <= .unpublished }

    /// Group heading in lists that split by urgency.
    var title: String {
        switch self {
        case .problem: "Needs a Fix"
        case .readyToPush: "Ready to Push"
        case .changes: "Changes"
        case .unpublished: "Not Published"
        case .behind: "Updates Available"
        case .dormant: "Dormant"
        case .clear: "Up to Date"
        }
    }

    /// Group symbol, drawn in `tint` next to the group's title.
    var symbol: String {
        switch self {
        case .problem: "exclamationmark.triangle.fill"
        case .changes: "pencil.circle.fill"
        case .readyToPush: "arrow.up.circle.fill"
        case .unpublished: "icloud.and.arrow.up.fill"
        case .behind: "arrow.down.circle.fill"
        case .dormant: "moon.zzz.fill"
        case .clear: "checkmark.circle.fill"
        }
    }

    /// Status colour. Always paired with text or a symbol, never the only signal.
    var tint: Color {
        switch self {
        case .problem: .red
        case .readyToPush: .blue
        case .changes: .orange
        case .unpublished: .purple
        case .behind: .indigo
        case .dormant: .secondary
        case .clear: .green
        }
    }
}

extension RepoItem {
    /// Changes older than this stop counting as "needs you" (roughly six months).
    static let dormantAfter: TimeInterval = 182 * 24 * 60 * 60

    var urgency: RepoUrgency {
        if let problem, !problem.isWarning, !problem.isInfo { return .problem }
        guard let status else { return .clear }
        if status.operation != nil || !status.conflicted.isEmpty { return .problem }
        if status.hasChanges {
            if status.branch.ahead == 0, let lastEditedAt, Date.now.timeIntervalSince(lastEditedAt) > Self.dormantAfter {
                return .dormant
            }
            return .changes
        }
        switch status.syncState {
        case .ahead, .diverged: return .readyToPush
        // A worktree's local-only branch is parked work (often a tool's), not a to-do.
        case .unpublished: return status.branch.hasCommits && worktreeOf == nil ? .unpublished : .clear
        case .upstreamGone: return .unpublished
        case .behind: return .behind
        case .upToDate, .noRemote: return .clear
        }
    }
}

extension RepoItem {
    /// Stack order: pinned first, then by urgency, then the most recently edited, then by name.
    func comesBefore(_ other: RepoItem) -> Bool {
        if isPinned != other.isPinned { return isPinned }
        let (ua, ub) = (urgency, other.urgency)
        if ua != ub { return ua < ub }
        let (da, db) = (lastEditedAt ?? .distantPast, other.lastEditedAt ?? .distantPast)
        if da != db { return da > db }
        return name.localizedStandardCompare(other.name) == .orderedAscending
    }
}

extension Sequence where Element == RepoItem {
    /// Pinned first, then by urgency, then the most recently edited, then by name.
    func sortedByUrgency() -> [RepoItem] {
        sorted { $0.comesBefore($1) }
    }
}
