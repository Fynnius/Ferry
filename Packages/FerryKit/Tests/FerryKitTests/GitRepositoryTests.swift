import Foundation
import Testing
@testable import FerryKit

/// Real git against temp repos and a local bare "remote".
@Suite("Git operations (real git)")
struct GitRepositoryTests {
    @Test func freshCloneIsCleanAndUpToDate() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        let status = try await repo.status()
        #expect(status.branch.head == "main")
        #expect(status.branch.upstream == "origin/main")
        #expect(status.syncState == .upToDate)
        #expect(!status.hasChanges)
        #expect(PrimaryAction(status: status) == .none)
    }

    @Test func commitAllStagesEverythingIncludingNewFiles() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        try fx.write("README.md", "# Changed\n", in: repo.root)
        try fx.write("src/new file.swift", "let x = 1\n", in: repo.root)

        var status = try await repo.status()
        #expect(PrimaryAction(status: status) == .commit(all: true))
        #expect(status.untracked.map(\.path) == ["src/new file.swift"])

        try await repo.commit(message: "Update readme and add file", all: true)
        status = try await repo.status()
        #expect(!status.hasChanges)
        #expect(status.syncState == .ahead(1))
        #expect(try await repo.lastCommitMessage() == "Update readme and add file")
    }

    @Test func commitWithStagedChangesLeavesTheRest() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(initialFiles: ["a.txt": "a\n", "b.txt": "b\n"]), as: "app")
        try fx.write("a.txt", "a2\n", in: repo.root)
        try fx.write("b.txt", "b2\n", in: repo.root)
        let before = try await repo.status()
        try await repo.stage(before.unstaged.filter { $0.path == "a.txt" })

        let staged = try await repo.status()
        #expect(staged.staged.map(\.path) == ["a.txt"])
        #expect(PrimaryAction(status: staged) == .commit(all: false))

        try await repo.commit(message: "Only a")
        let after = try await repo.status()
        #expect(after.staged.isEmpty)
        #expect(after.unstaged.map(\.path) == ["b.txt"])
    }

    @Test func unstageRestoresFiles() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        try fx.write("README.md", "changed\n", in: repo.root)
        try fx.write("new.txt", "new\n", in: repo.root)
        try await repo.stageAll()
        var status = try await repo.status()
        #expect(status.staged.count == 2)

        try await repo.unstage(status.staged.filter { $0.path == "new.txt" })
        status = try await repo.status()
        #expect(status.staged.map(\.path) == ["README.md"])
        #expect(status.untracked.map(\.path) == ["new.txt"])

        try await repo.unstageAll()
        status = try await repo.status()
        #expect(status.staged.isEmpty)
        #expect(status.unstaged.map(\.path) == ["README.md"])
    }

    @Test func stagedRenameUnstagesBothSides() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(initialFiles: ["old.txt": "same content here\n"]), as: "app")
        try await fx.git(["mv", "old.txt", "new.txt"], in: repo.root)
        var status = try await repo.status()
        #expect(status.staged.first?.kind == .renamed)
        #expect(status.staged.first?.originalPath == "old.txt")

        try await repo.unstage(status.staged)
        status = try await repo.status()
        #expect(status.staged.isEmpty)
        #expect(status.unstaged.map(\.path) == ["old.txt"])
        #expect(status.untracked.map(\.path) == ["new.txt"])
    }

    @Test func pushAndPublish() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        try fx.write("x.txt", "x\n", in: repo.root)
        try await repo.commit(message: "Add x", all: true)
        try await repo.push()
        #expect(try await repo.status().syncState == .upToDate)

        try await fx.git(["switch", "-q", "-c", "feature/y"], in: repo.root)
        try fx.write("y.txt", "y\n", in: repo.root)
        try await repo.commit(message: "Add y", all: true)
        var status = try await repo.status()
        #expect(status.syncState == .unpublished)
        #expect(PrimaryAction(status: status) == .publish)

        do {
            try await repo.push()
            Issue.record("push without upstream should fail")
        } catch let error as GitError {
            #expect(error.kind == .noUpstream)
        }

        try await repo.publish()
        status = try await repo.status()
        #expect(status.branch.upstream == "origin/feature/y")
        #expect(status.syncState == .upToDate)
    }

    @Test func syncPullsThenPushes() async throws {
        let fx = try await GitFixture.make()
        let remote = try await fx.makeRemote()
        let mine = try await fx.clone(remote, as: "mine")
        let theirs = try await fx.clone(remote, as: "theirs")
        try await fx.commitAndPush(in: theirs, path: "theirs.txt", contents: "t\n", message: "Theirs")
        try fx.write("mine.txt", "m\n", in: mine.root)
        try await mine.commit(message: "Mine", all: true)

        try await mine.fetch()
        let diverged = try await mine.status()
        #expect(diverged.syncState == .diverged(ahead: 1, behind: 1))

        do {
            try await mine.push()
            Issue.record("push of a diverged branch should be rejected")
        } catch let error as GitError {
            #expect(error.kind == .pushRejectedBehind)
            #expect(error.summary.contains("Pull first"))
        }

        try await mine.sync()
        let synced = try await mine.status()
        #expect(synced.syncState == .upToDate)
        #expect(FileManager.default.fileExists(atPath: mine.root.appendingPathComponent("theirs.txt").path))
    }

    @Test(arguments: [
        (config: "", fallback: GitRepository.PullStrategy.merge, expectMerges: true),
        (config: "", fallback: GitRepository.PullStrategy.rebase, expectMerges: false),
        (config: "[pull]\n    rebase = true", fallback: GitRepository.PullStrategy.merge, expectMerges: false),
    ])
    func pullStrategyRespectsConfigAndFallsBackWhenUnset(config: String, fallback: GitRepository.PullStrategy, expectMerges: Bool) async throws {
        let fx = try await GitFixture.make(extraConfig: config)
        let remote = try await fx.makeRemote()
        let mine = try await fx.clone(remote, as: "mine")
        let theirs = try await fx.clone(remote, as: "theirs")
        try await fx.commitAndPush(in: theirs, path: "t.txt", contents: "t\n", message: "Theirs")
        try fx.write("m.txt", "m\n", in: mine.root)
        try await mine.commit(message: "Mine", all: true)

        try await mine.sync(fallback: fallback)
        let merges = try await fx.git(["rev-list", "--merges", "HEAD"], in: mine.root)
        #expect(merges.isEmpty != expectMerges)
        #expect(try await mine.status().syncState == .upToDate)
    }

    @Test func pullWithConflictReportsConflictsAndMergeInProgress() async throws {
        let fx = try await GitFixture.make(extraConfig: "[pull]\n    rebase = false")
        let remote = try await fx.makeRemote(initialFiles: ["shared.txt": "base\n"])
        let mine = try await fx.clone(remote, as: "mine")
        let theirs = try await fx.clone(remote, as: "theirs")
        try await fx.commitAndPush(in: theirs, path: "shared.txt", contents: "theirs\n", message: "Theirs")
        try fx.write("shared.txt", "mine\n", in: mine.root)
        try await mine.commit(message: "Mine", all: true)

        do {
            try await mine.pull()
            Issue.record("conflicting pull should fail")
        } catch let error as GitError {
            #expect(error.kind == .conflicts)
        }
        let status = try await mine.status()
        #expect(status.operation == .merge)
        #expect(status.conflicted.map(\.path) == ["shared.txt"])
        #expect(PrimaryAction(status: status) == .none)
    }

    @Test func failingHookRollsBackCommitAllStaging() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        try fx.installHook("pre-commit", script: "echo 'lint: 2 problems in app.js' >&2; exit 1", in: repo)
        try fx.write("app.js", "var x\n", in: repo.root)

        do {
            try await repo.commit(message: "Add app", all: true)
            Issue.record("commit should be stopped by the hook")
        } catch let error as GitError {
            #expect(error.kind == .hookFailed)
            #expect(error.output.contains("lint: 2 problems"))
        }
        let status = try await repo.status()
        #expect(status.staged.isEmpty, "Commit All must leave the repo as it was when the commit fails")
        #expect(status.untracked.map(\.path) == ["app.js"])
    }

    @Test func prePushHookFailureIsAHookError() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        try fx.installHook("pre-push", script: "echo 'tests failed' >&2; exit 1", in: repo)
        try fx.write("a.txt", "a\n", in: repo.root)
        try await repo.commit(message: "A", all: true)
        do {
            try await repo.push()
            Issue.record("push should be stopped by the hook")
        } catch let error as GitError {
            #expect(error.kind == .hookFailed)
        }
    }

    @Test func undoLastCommitKeepsChangesStagedAndReturnsMessage() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        try fx.write("a.txt", "a\n", in: repo.root)
        try await repo.commit(message: "Add a\n\nWith a body.", all: true)

        let message = try await repo.undoLastCommit()
        #expect(message == "Add a\n\nWith a body.")
        let status = try await repo.status()
        #expect(status.staged.map(\.path) == ["a.txt"])
        #expect(status.syncState == .upToDate)
    }

    @Test func emptyRepoCommitAndUndoRootCommit() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.makeRepo("empty")
        var status = try await repo.status()
        #expect(!status.branch.hasCommits)
        #expect(status.syncState == .noRemote)
        #expect(!status.needsAttention)

        try fx.write("first.txt", "1\n", in: repo.root)
        try await repo.stageAll()
        try await repo.unstageAll()
        status = try await repo.status()
        #expect(status.untracked.map(\.path) == ["first.txt"])

        try await repo.commit(message: "First", all: true)
        #expect(try await repo.hasCommits())
        try await repo.undoLastCommit()
        #expect(try await !repo.hasCommits())
        status = try await repo.status()
        #expect(status.staged.map(\.path) == ["first.txt"])
    }

    @Test func amendReplacesTheLastCommit() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        try fx.write("a.txt", "a\n", in: repo.root)
        try await repo.commit(message: "Typo msg", all: true)
        try await repo.commit(message: "Fixed message", amend: true)
        #expect(try await repo.lastCommitMessage() == "Fixed message")
        #expect(try await repo.status().syncState == .ahead(1))
    }

    @Test func staleIndexLockIsReportedClearly() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        try fx.write("a.txt", "a\n", in: repo.root)
        FileManager.default.createFile(atPath: repo.root.appendingPathComponent(".git/index.lock").path, contents: nil)

        // Reads still work under a lock.
        #expect(try await repo.status().untracked.count == 1)
        do {
            try await repo.stageAll()
            Issue.record("staging under index.lock should fail")
        } catch let error as GitError {
            #expect(error.kind == .indexLocked)
        }
    }

    @Test func missingIdentityIsExplained() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.makeRepo("anon")
        try await fx.git(["config", "user.name", ""], in: repo.root)
        try await fx.git(["config", "user.email", ""], in: repo.root)
        try await fx.git(["config", "user.useConfigOnly", "true"], in: repo.root)
        try fx.write("a.txt", "a\n", in: repo.root)
        do {
            try await repo.commit(message: "A", all: true)
            Issue.record("commit without identity should fail")
        } catch let error as GitError {
            #expect(error.kind == .identityMissing)
        }
    }

    @Test func emptyMessageCommitIsRefusedByGit() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        try fx.write("a.txt", "a\n", in: repo.root)
        await #expect(throws: GitError.self) {
            try await repo.commit(message: "   ", all: true)
        }
        #expect(try await repo.status().staged.isEmpty)
    }

    @Test func recentSubjects() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.clone(try await fx.makeRemote(), as: "app")
        for i in 1...3 {
            try fx.write("f\(i).txt", "\(i)\n", in: repo.root)
            try await repo.commit(message: "feat: add f\(i)", all: true)
        }
        let subjects = try await repo.recentSubjects(limit: 2)
        #expect(subjects == ["feat: add f3", "feat: add f2"])
    }
}
