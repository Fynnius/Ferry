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

    /// `main` merging a long-lived `staging` branch twelve times (a PR staircase): the
    /// log interleaves the two lines, so the graph needs two lanes, not one per merge.
    @Test func logKeepsARepeatedlyMergedBranchNarrow() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.makeRepo("staircase")
        var time = 1_700_000_000
        var stream = ""
        func commit(_ ref: String, mark: Int, from: Int?, merge: Int? = nil) {
            time += 60
            stream += "commit refs/heads/\(ref)\nmark :\(mark)\ncommitter T <t@ferry.invalid> \(time) +0000\ndata 1\nc\n"
            if let from { stream += "from :\(from)\n" }
            if let merge { stream += "merge :\(merge)\n" }
        }
        commit("main", mark: 1, from: nil)
        var (main, staging, mark) = (1, 1, 1)
        for _ in 1...12 {
            for _ in 1...2 {
                mark += 1
                commit("staging", mark: mark, from: staging)
                staging = mark
            }
            mark += 1
            commit("main", mark: mark, from: main, merge: staging)
            main = mark
        }
        // Staging moves on, then merges main back and is checked out. Topo order would
        // print all twelve merges before any staging commit, one open lane each.
        for _ in 1...3 {
            mark += 1
            commit("staging", mark: mark, from: staging)
            staging = mark
        }
        commit("staging", mark: mark + 1, from: staging, merge: main)
        try await fx.runner.run(["fast-import", "--quiet"], in: repo.root, as: .write, stdin: Data(stream.utf8))
        try await fx.git(["symbolic-ref", "HEAD", "refs/heads/staging"], in: repo.root)

        let commits = try await repo.log()
        #expect(commits.count == 41)
        #expect(GraphLayout.rows(for: commits).map(\.width).max() == 2)
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

    /// A mainline merging one long-lived branch again and again — the shape of a
    /// `staging` → `main` PR staircase, and of the 50-merge history that pushed every
    /// subject off-screen. Merge k takes branch commits s(2k-1) and s(2k).
    private func staircase(merges n: Int) -> (topo: [Commit], date: [Commit]) {
        func m(_ k: Int) -> Commit { c("m\(k)", k == 1 ? "base" : "m\(k - 1)", "s\(2 * k)") }
        func s(_ i: Int) -> Commit { c("s\(i)", i == 1 ? "base" : "s\(i - 1)") }
        // Topo order prints each line as a block: every merge, then the whole branch.
        let topo = (1...n).reversed().map(m) + (1...2 * n).reversed().map(s) + [c("base")]
        // Date order interleaves them as they happened.
        let date = (1...n).reversed().flatMap { [m($0), s(2 * $0), s(2 * $0 - 1)] } + [c("base")]
        return (topo, date)
    }

    @Test func repeatedMergesOfOneBranchNeedTwoLanesInDateOrder() {
        let shape = staircase(merges: 50)
        let date = GraphLayout.rows(for: shape.date)
        #expect(date.allSatisfy { $0.width <= 2 })
        // The same history in topo order holds a lane open per merge: the lanes are real
        // (each merge's line runs down to its commit), so the fix is the order.
        #expect(GraphLayout.rows(for: shape.topo).map(\.width).max() == 51)
    }

    @Test func lanesCloseWhereTheirCommitIs() {
        let rows = GraphLayout.rows(for: staircase(merges: 12).topo)
        // Every lane a merge opens ends at its branch commit: widest right after the
        // merges, and at the root only the two real lines are left, with nothing below.
        let branch = rows.drop { !$0.commit.id.hasPrefix("s") }
        #expect(branch.first?.width == 13)
        #expect(rows.last?.width == 2)
        #expect(rows.last?.segments.contains { if case .bottom = $0.to { true } else { false } } == false)
    }

    @Test func pagingNeverChangesRowsAlreadyShown() {
        let all = staircase(merges: 20).date
        let full = GraphLayout.rows(for: all)
        for page in [7, 30] {
            let partial = GraphLayout.rows(for: Array(all.prefix(page)))
            #expect(partial == Array(full.prefix(page)))
            // The last loaded row's parents are on the next page: their lanes run to the
            // bottom edge and continue there.
            #expect(partial.last?.segments.contains { if case .bottom = $0.to { true } else { false } } == true)
        }
    }
}
