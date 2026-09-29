import Foundation
import Testing
@testable import Ferry
import FerryKit

@MainActor
@Suite("Menu bar and Dock menu")
struct AttentionMenuTests {
    private let tracked = BranchState(head: "main", oid: "abc", upstream: "origin/main")

    private func item(_ name: String, branch: BranchState? = nil, changes: Int = 0, edited: Date? = nil, conflicted: Bool = false) -> RepoItem {
        let files = (0..<changes).map { FileChange(path: "f\($0)", kind: .modified, area: .unstaged) }
        let conflicts = conflicted ? [FileChange(path: "x", kind: .conflicted, area: .conflicted)] : []
        let item = RepoItem(id: name, name: name, path: URL(fileURLWithPath: "/tmp/\(name)"), status: RepoStatus(branch: branch ?? tracked, unstaged: files, conflicted: conflicts))
        item.lastEditedAt = edited
        return item
    }

    @Test func sectionsFollowWhatYouDoNext() {
        let older = item("older", changes: 2, edited: .now.addingTimeInterval(-3600))
        let newer = item("newer", changes: 1, edited: .now)
        let push = item("push", branch: BranchState(head: "main", oid: "abc", upstream: "origin/main", ahead: 2))
        let fix = item("fix", conflicted: true)
        let unpublished = item("feature", branch: BranchState(head: "feature", oid: "abc"))
        let behind = item("behind", branch: BranchState(head: "main", oid: "abc", upstream: "origin/main", behind: 189))
        let clean = item("clean")
        let menu = AttentionMenu(repos: [older, clean, behind, unpublished, newer, push, fix])

        #expect(menu.sections.map(\.urgency) == [.problem, .changes, .readyToPush, .unpublished])
        #expect(menu.sections.flatMap(\.repos).map(\.name) == ["fix", "newer", "older", "push", "feature"])
        #expect(menu.updates.map(\.name) == ["behind"], "behind-only repos are a quiet line, not a row")
        #expect(menu.moreTitle == nil)
        #expect(menu.summary == "1 needs a fix · 2 with changes · 1 to push · 1 not published")
        #expect(menu.pullAllTitle == "Pull 1 Repo with Updates")
    }

    @Test func capsRowsAndCountsTheRest() {
        let repos = (0..<15).map { item("r\($0)", changes: 1, edited: .now.addingTimeInterval(Double(-$0))) }
            + [item("push", branch: BranchState(head: "main", oid: "abc", upstream: "origin/main", ahead: 1))]
        let menu = AttentionMenu(repos: repos, limit: 12)
        #expect(menu.sections.flatMap(\.repos).count == 12)
        #expect(menu.sections.first?.repos.map(\.name) == (0..<12).map { "r\($0)" }, "the most urgent, most recent first, make the cut")
        #expect(menu.moreTitle == "and 4 more — Open Ferry")
        #expect(menu.summary == "15 with changes · 1 to push", "the summary counts every repo, shown or not")
    }

    @Test func allClearAndUpdatesOnly() {
        #expect(AttentionMenu(repos: [item("a"), item("b")]).summary == "All 2 repos are clear")
        let behind = [3, 5].map { item("b\($0)", branch: BranchState(head: "main", oid: "abc", upstream: "origin/main", behind: $0)) }
        let menu = AttentionMenu(repos: behind + [item("a")])
        #expect(menu.sections.isEmpty)
        #expect(menu.summary == "Nothing needs you · 2 repos have updates")
        #expect(menu.pullAllTitle == "Pull 2 Repos with Updates")
    }

    @Test func rowsReadWellAtScale() {
        let huge = item("huge-app", branch: BranchState(head: "main", oid: "abc", upstream: "origin/main", behind: 1_189), changes: 13_277, edited: .now)
        let menu = AttentionMenu(repos: [huge])
        #expect(menu.title(for: huge) == "huge-app — \(13_277.formatted()) changed (check .gitignore) · \(1_189.formatted())↓")

        let small = item("api", changes: 29, edited: .now)
        #expect(AttentionMenu(repos: [small]).title(for: small) == "api — 29 changed")
    }

    @Test func worktreesReadAsParentAndBranch() {
        let parent = item("TideMobile")
        let worktree = item("wt_3f2a9c1b-89e-1", branch: BranchState(head: "feat/home-shell", oid: "abc", upstream: "origin/feat/home-shell"), changes: 3, edited: .now)
        worktree.worktreeOf = parent.id
        let menu = AttentionMenu(repos: [parent, worktree])
        #expect(menu.title(for: worktree) == "TideMobile › feat/home-shell — 3 changed")
    }
}
