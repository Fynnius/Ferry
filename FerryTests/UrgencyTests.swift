import Foundation
import Testing
@testable import Ferry
import FerryKit

@MainActor
@Suite("Repo urgency")
struct UrgencyTests {
    private func item(_ name: String, branch: BranchState = BranchState(head: "main", oid: "abc", upstream: "origin/main"), changes: [FileChange] = [], edited: Date? = nil) -> RepoItem {
        let item = RepoItem(id: name, name: name, path: URL(fileURLWithPath: "/tmp/\(name)"), status: RepoStatus(branch: branch, unstaged: changes))
        item.lastEditedAt = edited
        return item
    }

    private let file = FileChange(path: "a.txt", kind: .modified, area: .unstaged)

    @Test func behindOnlyDoesNotNeedYou() {
        let behind = item("b", branch: BranchState(head: "main", oid: "abc", upstream: "origin/main", behind: 189))
        #expect(behind.urgency == .behind)
        #expect(!behind.needsAttention)
        #expect(behind.hasSomethingPending)
    }

    @Test func oldChangesGoDormantUnlessThereIsSomethingToPush() {
        let old = Date.now.addingTimeInterval(-RepoItem.dormantAfter - 86_400)
        let dormant = item("d", changes: [file], edited: old)
        #expect(dormant.urgency == .dormant)
        #expect(!dormant.needsAttention)

        let recent = item("r", changes: [file], edited: .now)
        #expect(recent.urgency == .changes)
        #expect(recent.needsAttention)

        let oldButAhead = item("a", branch: BranchState(head: "main", oid: "abc", upstream: "origin/main", ahead: 1), changes: [file], edited: old)
        #expect(oldButAhead.urgency == .changes)
    }

    @Test func orderIsPinnedThenChangesThenPushThenMostRecentEdit() {
        let pushable = item("push", branch: BranchState(head: "main", oid: "abc", upstream: "origin/main", ahead: 2))
        let older = item("older", changes: [file], edited: .now.addingTimeInterval(-3600))
        let newer = item("newer", changes: [file], edited: .now)
        let behind = item("behind", branch: BranchState(head: "main", oid: "abc", upstream: "origin/main", behind: 3))
        let clean = item("clean")
        clean.isPinned = true
        let order = [behind, older, clean, newer, pushable].sortedByUrgency().map(\.name)
        #expect(order == ["clean", "newer", "older", "push", "behind"])
    }

    @Test func conflictsAndFailuresComeFirst() {
        let conflicted = RepoItem(id: "c", name: "c", path: URL(fileURLWithPath: "/tmp/c"), status: RepoStatus(branch: BranchState(head: "main", oid: "abc"), conflicted: [FileChange(path: "x", kind: .conflicted, area: .conflicted)]))
        #expect(conflicted.urgency == .problem)
        let failed = item("f")
        failed.problem = RepoProblem(message: "hook failed")
        #expect(failed.urgency == .problem)
        failed.problem = RepoProblem(message: "offline", isWarning: true)
        #expect(failed.urgency == .clear)
    }
}
