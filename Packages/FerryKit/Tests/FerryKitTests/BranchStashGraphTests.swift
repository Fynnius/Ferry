import Foundation
import Testing
@testable import FerryKit

@Suite("Branches, stash and history (real git)")
struct BranchStashGraphTests {
    @Test func listCreateSwitchRenameDelete() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")

        try await repo.createBranch("feature/a")
        var branches = try await repo.branches()
        #expect(branches.first?.name == "feature/a")
        #expect(branches.first?.isCurrent == true)
        #expect(branches.contains { $0.name == "origin/main" && $0.isRemote })
        #expect(!branches.contains { $0.name.hasSuffix("/HEAD") })

        #expect(await repo.isValidBranchName("feature/b"))
        #expect(await !repo.isValidBranchName("bad name"))
        #expect(await !repo.isValidBranchName("bad..name"))

        try await repo.renameBranch("feature/a", to: "feature/renamed")
        try fx.write("a.txt", "a\n", in: repo.root)
        try await repo.commit(message: "Work on feature", all: true)

        let main = try #require(try await repo.branches().first { $0.name == "main" })
        try await repo.switchTo(main)
        #expect(try await repo.status().branch.head == "main")

        do {
            try await repo.deleteBranch("feature/renamed")
            Issue.record("deleting an unmerged branch should need force")
        } catch let error as GitError {
            #expect(error.kind == .branchNotFullyMerged)
        }
        try await repo.deleteBranch("feature/renamed", force: true)
        branches = try await repo.branches()
        #expect(!branches.contains { $0.name == "feature/renamed" })
    }

    @Test func switchingToARemoteBranchCreatesTrackingBranch() async throws {
        let fx = try await GitFixture.make()
        let remote = try await fx.makeRemote()
        let other = try await fx.clone(remote, as: "other")
        try await fx.git(["switch", "-q", "-c", "topic"], in: other.root)
        try fx.write("t.txt", "t\n", in: other.root)
        try await fx.git(["add", "-A"], in: other.root)
        try await fx.git(["commit", "-q", "-m", "Topic"], in: other.root)
        try await fx.git(["push", "-q", "-u", "origin", "topic"], in: other.root)

        let repo = try await fx.clone(remote, as: "app")
        let remoteTopic = try #require(try await repo.branches().first { $0.name == "origin/topic" })
        try await repo.switchTo(remoteTopic)
        let status = try await repo.status()
        #expect(status.branch.head == "topic")
        #expect(status.branch.upstream == "origin/topic")
    }

    @Test func switchBlockedByLocalChangesExplainsWhy() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(initialFiles: ["f.txt": "base\n"]), as: "app")
        try await repo.createBranch("other")
        try fx.write("f.txt", "other\n", in: repo.root)
        try await repo.commit(message: "Other", all: true)
        let main = try #require(try await repo.branches().first { $0.name == "main" })
        try await repo.switchTo(main)
        try fx.write("f.txt", "dirty\n", in: repo.root)
        let other = try #require(try await repo.branches().first { $0.name == "other" })
        do {
            try await repo.switchTo(other)
            Issue.record("switch should refuse to overwrite local changes")
        } catch let error as GitError {
            #expect(error.kind == .localChangesWouldBeOverwritten)
        }
    }

    @Test func stashRoundTrip() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        try fx.write("README.md", "changed\n", in: repo.root)
        try fx.write("new.txt", "new\n", in: repo.root)

        try await repo.stash(message: "WIP: readme")
        #expect(!(try await repo.status().hasChanges))
        var stashes = try await repo.stashes()
        #expect(stashes.count == 1)
        #expect(stashes[0].message.contains("WIP: readme"))
        #expect(try await repo.status().stashCount == 1)

        try await repo.applyStash(stashes[0])
        #expect(try await repo.status().changedPathCount == 2)
        try await repo.stash(message: "second")
        stashes = try await repo.stashes()
        #expect(stashes.count == 2)
        #expect(stashes[0].message.contains("second"))

        try await repo.dropStash(stashes[1])
        try await repo.popStash(try await repo.stashes()[0])
        #expect(try await repo.stashes().isEmpty)
        #expect(try await repo.status().changedPathCount == 2)
    }

    @Test func logIncludesUpstreamAndParsesDecorations() async throws {
        let fx = try await GitFixture.make()
        let remote = try await fx.makeRemote()
        let repo = try await fx.clone(remote, as: "app")
        let theirs = try await fx.clone(remote, as: "theirs")
        try await fx.commitAndPush(in: theirs, path: "t.txt", contents: "t\n", message: "Theirs | with pipe")
        try fx.write("m.txt", "m\n", in: repo.root)
        try await repo.commit(message: "Mine", all: true)
        try await repo.fetch()

        let commits = try await repo.log()
        #expect(commits.count == 3)
        #expect(Set(commits.map(\.subject)) == ["Mine", "Theirs | with pipe", "Initial commit"])
        #expect(commits.first { $0.subject == "Mine" }?.refs.contains("HEAD -> main") == true)
        #expect(commits.first { $0.subject == "Initial commit" }?.parents.isEmpty == true)

        let empty = try await fx.makeRepo("empty")
        #expect(try await empty.log().isEmpty)
    }
}

@Suite("Graph lane layout")
struct GraphLayoutTests {
    private func c(_ id: String, _ parents: String...) -> Commit {
        Commit(id: id, parents: parents, refs: [], author: "", email: "", date: .now, subject: id)
    }

    @Test func linearHistoryIsOneStraightLane() {
        let rows = GraphLayout.rows(for: [c("c", "b"), c("b", "a"), c("a")])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.map(\.width) == [1, 1, 1])
        #expect(rows[1].segments.contains(.init(from: .top(0), to: .node, colorLane: 0)))
        #expect(!rows[2].segments.contains { $0.to == .bottom(0) })
    }

    @Test func mergeOpensAndClosesASecondLane() {
        // m merges f into main; f and b both come from a.
        let rows = GraphLayout.rows(for: [c("m", "b", "f"), c("f", "a"), c("b", "a"), c("a")])
        #expect(rows[0].lane == 0)
        #expect(rows[0].segments.contains(.init(from: .node, to: .bottom(1), colorLane: 1)))
        #expect(rows[1].lane == 1)
        #expect(rows[2].lane == 0)
        #expect(rows[2].segments.contains(.init(from: .top(1), to: .bottom(1), colorLane: 1)))
        // Both lanes converge on the root.
        #expect(rows[3].lane == 0)
        #expect(rows[3].segments.contains(.init(from: .top(1), to: .node, colorLane: 1)))
        #expect(rows[3].width == 2)
    }

    @Test func freedLanesAreReused() {
        let rows = GraphLayout.rows(for: [
            c("m2", "m1", "x"), c("x", "m1"),
            c("m1", "base", "y"), c("y", "base"),
            c("base"),
        ])
        #expect(rows.map(\.lane) == [0, 1, 0, 1, 0])
        #expect(rows.allSatisfy { $0.width <= 2 })
    }

    @Test func twoBranchTipsWithoutMergeGetTheirOwnLanes() {
        let rows = GraphLayout.rows(for: [c("t1", "a"), c("t2", "a"), c("a")])
        #expect(rows[0].lane == 0)
        #expect(rows[1].lane == 1)
        #expect(rows[2].lane == 0)
    }
}
