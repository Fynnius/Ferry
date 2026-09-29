import Foundation
import FerryKit

/// The glanceable "what needs me" text and the jump to one repo, shared by the menu bar
/// extra and the Dock menu so both always say the same thing.
extension AppModel {
    /// One line such as "2 with changes · 1 unpushed", or "All 12 repos are clear".
    func attentionSummary(_ attention: [RepoItem]) -> String {
        let changed = attention.filter { $0.status?.hasChanges == true }.count
        let unpushed = attention.filter { ($0.status?.branch.ahead ?? 0) > 0 }.count
        if attention.isEmpty { return "All \(allRepos.count) repos are clear" }
        var parts: [String] = []
        if changed > 0 { parts.append("\(changed) with changes") }
        if unpushed > 0 { parts.append("\(unpushed) unpushed") }
        if parts.isEmpty { parts.append("\(attention.count) need attention") }
        return parts.joined(separator: " · ")
    }

    /// Shows a repo from a menu (menu bar extra, Dock): in Needs Attention, current, with
    /// the keyboard in its message field. The caller brings the window forward first.
    func showFromMenu(_ repo: RepoItem) {
        selection = .attention
        focus(repo)
    }
}

extension RepoItem {
    /// The repo's state in a few words for menus, e.g. "3 changed, 2↑".
    var stateSummary: String {
        guard let status else { return "…" }
        var parts: [String] = []
        if status.hasChanges { parts.append("\(status.changedPathCount) changed") }
        switch status.syncState {
        case .ahead(let n): parts.append("\(n)↑")
        case .behind(let n): parts.append("\(n)↓")
        case .diverged(let a, let b): parts.append("\(a)↑ \(b)↓")
        case .unpublished: parts.append("not published")
        default: break
        }
        return parts.joined(separator: ", ")
    }

    /// "name  —  state", the row title in the menu bar extra and the Dock menu.
    var menuTitle: String { "\(name)  —  \(stateSummary)" }
}
