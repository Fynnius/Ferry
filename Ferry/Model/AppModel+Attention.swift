import Foundation
import FerryKit

/// What the menu bar extra and the Dock menu list, so both always say the same thing:
/// repos that need you in sections by what you do next (fix → push → commit → publish),
/// most recently edited first, capped so the menu stays short; repos that only need a
/// pull as one quiet line. A pure function of the repos, for tests.
struct AttentionMenu {
    struct Section: Identifiable {
        var urgency: RepoUrgency
        var repos: [RepoItem]
        var id: RepoUrgency { urgency }
    }

    /// At most this many repo rows; the rest are "and N more".
    static let rowLimit = 12

    var sections: [Section]
    /// Repos that need you but didn't fit under the row limit.
    var moreCount: Int
    /// Behind-only repos: nothing to do but pull, so they don't count as needing you.
    var updates: [RepoItem]
    /// Every repo that needs you, shown or not, per urgency.
    private var counts: [RepoUrgency: Int]
    private var totalCount: Int
    /// Parent names for worktree rows.
    private var names: [String: String]

    init(repos: [RepoItem], limit: Int = AttentionMenu.rowLimit) {
        // Pinning doesn't count here: the menu is about what to do next.
        let needing = repos.filter(\.needsAttention).sorted { a, b in
            let (ua, ub) = (a.urgency, b.urgency)
            if ua != ub { return ua < ub }
            let (da, db) = (a.lastEditedAt ?? .distantPast, b.lastEditedAt ?? .distantPast)
            if da != db { return da > db }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let shown = needing.prefix(limit)
        sections = RepoUrgency.allCases.compactMap { urgency in
            let members = shown.filter { $0.urgency == urgency }
            return members.isEmpty ? nil : Section(urgency: urgency, repos: members)
        }
        moreCount = needing.count - shown.count
        updates = repos.filter { $0.urgency == .behind && !$0.isSnoozed }
        counts = Dictionary(grouping: needing, by: \.urgency).mapValues(\.count)
        totalCount = repos.count
        names = Dictionary(repos.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// "TideApp — 29 changed · 189↓"; a worktree reads "Parent › branch — …".
    func title(for repo: RepoItem) -> String {
        let name = repo.menuName(parentName: repo.worktreeOf.flatMap { names[$0] })
        let state = repo.stateSummary
        return state.isEmpty ? name : "\(name) — \(state)"
    }

    /// One line such as "1 needs a fix · 2 to push · 5 with changes", over every repo
    /// that needs you, not just the rows shown.
    var summary: String {
        guard !counts.isEmpty else {
            if updates.isEmpty { return "All \(totalCount) repos are clear" }
            return updates.count == 1 ? "Nothing needs you · 1 repo has updates" : "Nothing needs you · \(updates.count) repos have updates"
        }
        return RepoUrgency.allCases.compactMap { urgency -> String? in
            guard let count = counts[urgency] else { return nil }
            switch urgency {
            case .problem: return count == 1 ? "1 needs a fix" : "\(count) need a fix"
            case .readyToPush: return "\(count) to push"
            case .changes: return "\(count) with changes"
            case .unpublished: return "\(count) not published"
            case .behind, .dormant, .clear: return nil
            }
        }.joined(separator: " · ")
    }

    /// "and 45 more — Open Ferry", under the last section.
    var moreTitle: String? { moreCount > 0 ? "and \(moreCount) more — Open Ferry" : nil }

    var pullAllTitle: String { updates.count == 1 ? "Pull 1 Repo with Updates" : "Pull \(updates.count) Repos with Updates" }
}

extension AppModel {
    var attentionMenu: AttentionMenu { AttentionMenu(repos: allRepos) }

    /// Shows a repo from a menu (menu bar extra, Dock): in Needs Attention, current, with
    /// the keyboard in its message field. The caller brings the window forward first.
    func showFromMenu(_ repo: RepoItem) {
        selection = .attention
        focus(repo)
    }

    /// Pulls repos that only have updates waiting (behind-only: no local changes).
    func pullAll(_ repos: [RepoItem]) async {
        await withTaskGroup(of: Void.self) { group in
            for repo in repos {
                group.addTask { await repo.pull() }
            }
        }
    }
}

extension RepoItem {
    /// The repo's state in a few words for menus, e.g. "3 changed · 2↑". Counts get
    /// grouping separators; a count too large to be real work hints at .gitignore.
    var stateSummary: String {
        guard let status else { return "…" }
        var parts: [String] = []
        if status.hasChanges {
            let count = status.changedPathCount
            parts.append(count > ChangeList.manyChanges ? "\(count.formatted()) changed (check .gitignore)" : "\(count.formatted()) changed")
        }
        switch status.syncState {
        case .ahead(let n): parts.append("\(n.formatted())↑")
        case .behind(let n): parts.append("\(n.formatted())↓")
        case .diverged(let a, let b): parts.append("\(a.formatted())↑ \(b.formatted())↓")
        case .unpublished: parts.append("not published")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    /// The repo's name in menus. A worktree reads "Parent › branch" instead of its folder
    /// name, which is often generated (`wt_3f2a9c1b-89e-1`).
    func menuName(parentName: String?) -> String {
        guard let parentName else { return name }
        return "\(parentName) › \(status?.branch.head ?? name)"
    }
}
