import Foundation
import Testing
@testable import Ferry
import FerryKit

@MainActor
@Suite("Stash and retry (app layer, real git)")
struct StashAndRetryTests {
    @Test func refusedSwitchStashesAndSwitches() async throws {
        let repos = try await TestRepos()
        let item = try await repos.clonedItem()
        try await repos.git(["switch", "-q", "-c", "feature"], in: item.path)
        try repos.write("README.md", "# feature\n", in: item.path)
        try await repos.git(["commit", "-q", "-am", "Feature readme"], in: item.path)
        try await repos.git(["switch", "-q", "main"], in: item.path)
        try repos.write("README.md", "# my edit\n", in: item.path)
        try repos.write("notes.txt", "untracked\n", in: item.path)
        await item.refresh()
        let feature = try #require(try await item.git?.branches().first { $0.name == "feature" })

        #expect(await item.switchTo(feature) == false)
        let problem = try #require(item.problem)
        #expect(problem.fixes.first == .stashAndRetry(.switchTo(feature)))
        #expect(item.status?.branch.head == "main")

        await item.stashAndRetry(.switchTo(feature))
        #expect(item.status?.branch.head == "feature")
        #expect(item.status?.hasChanges == false, "untracked files went into the stash too")
        let stashes = try #require(try await item.git?.stashes())
        #expect(stashes.count == 1)
        #expect(stashes.first?.message.contains("Ferry: before switching to feature") == true)
        let notice = try #require(item.problem)
        #expect(notice.isInfo)
        #expect(notice.fixes == stashes.map { .popStash($0) })
    }

    @Test func refusedRebasePullStashesPullsAndPops() async throws {
        let repos = try await TestRepos()
        let item = try await repos.clonedItem()
        try await repos.git(["config", "pull.rebase", "true"], in: item.path)
        // Someone else pushes b.txt; locally a.txt is committed and README is being edited.
        let other = repos.root.appendingPathComponent("other")
        try await repos.git(["clone", "-q", repos.root.appendingPathComponent("app.git").path, other.path], in: repos.root)
        try repos.write("b.txt", "b\n", in: other)
        try await repos.git(["add", "-A"], in: other)
        try await repos.git(["commit", "-q", "-m", "Other"], in: other)
        try await repos.git(["push", "-q"], in: other)
        try repos.write("a.txt", "a\n", in: item.path)
        try await repos.git(["add", "-A"], in: item.path)
        try await repos.git(["commit", "-q", "-m", "Mine"], in: item.path)
        try await repos.git(["fetch", "-q"], in: item.path)
        try repos.write("README.md", "# work in progress\n", in: item.path)
        await item.refresh()

        #expect(await item.pull() == false)
        #expect(item.problem?.fixes.first == .stashAndRetry(.pull))

        await item.stashAndRetry(.pull)
        #expect(item.status?.branch.behind == 0)
        #expect(item.status?.branch.ahead == 1)
        #expect(FileManager.default.fileExists(atPath: item.path.appendingPathComponent("b.txt").path))
        let stash = try #require(try await item.git?.stashes().first)
        #expect(stash.message.contains("Ferry: before pulling"))
        #expect(item.problem?.fixes == [.popStash(stash)])

        await item.popStash(stash)
        #expect(item.problem == nil)
        #expect(try await item.git?.stashes().isEmpty == true)
        #expect(try String(contentsOf: item.path.appendingPathComponent("README.md"), encoding: .utf8) == "# work in progress\n")
    }

    @Test func stashFixOnlyWhenThereIsSomethingToRetry() {
        let error = GitError(kind: .localChangesWouldBeOverwritten, command: ["pull"], exitCode: 1, stderr: "error: Your local changes to the following files would be overwritten by merge")
        #expect(RepoProblem(error, retry: .pull).fixes.first == .stashAndRetry(.pull))
        #expect(!RepoProblem(error).fixes.contains { if case .stashAndRetry = $0 { true } else { false } })
    }

    @Test func stashNoticeIsNotSomethingToFix() {
        let repo = RepoItem(id: "r", name: "r", path: URL(fileURLWithPath: "/tmp/r"), status: RepoStatus(
            branch: BranchState(head: "main", oid: "x", upstream: "origin/main")
        ))
        repo.problem = RepoProblem(message: "Your changes are in the stash.", isInfo: true)
        #expect(!repo.needsAttention)
        #expect(repo.isActive, "it stays visible until dismissed")
    }
}
