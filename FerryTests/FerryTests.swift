import Foundation
import Testing
@testable import Ferry
import FerryKit

@MainActor
@Suite("Repo actions (app layer, real git)")
struct RepoItemTests {
    @Test func emptyMessageShakesInsteadOfCommitting() async throws {
        let repos = try await TestRepos()
        let item = try await repos.clonedItem()
        try repos.write("a.txt", "a\n", in: item.path)
        await item.refresh()

        await item.commit()
        #expect(item.shakeCount == 1)
        #expect(item.focusMessageCount == 1)
        #expect(item.status?.untracked.count == 1)
    }

    @Test func commitAllClearsMessageAndMovesToSync() async throws {
        let repos = try await TestRepos()
        let item = try await repos.clonedItem()
        try repos.write("a.txt", "a\n", in: item.path)
        await item.refresh()
        #expect(item.primaryAction == .commit(all: true))

        item.message = "Add a"
        await item.commit()
        #expect(item.message.isEmpty)
        #expect(item.problem == nil)
        #expect(item.successCount == 1)
        #expect(item.primaryAction == .sync(ahead: 1, behind: 0))
        #expect(item.lastCommitIsUnpushed)

        await item.sync()
        #expect(item.primaryAction == .none)
        #expect(!item.lastCommitIsUnpushed)
    }

    @Test func undoPutsTheMessageBack() async throws {
        let repos = try await TestRepos()
        let item = try await repos.clonedItem()
        try repos.write("a.txt", "a\n", in: item.path)
        await item.refresh()
        item.message = "Add a"
        await item.commit()
        await item.undoLastCommit()
        #expect(item.message == "Add a")
        #expect(item.status?.staged.map(\.path) == ["a.txt"])
    }

    @Test func hookFailureBecomesAProblemWithOutput() async throws {
        let repos = try await TestRepos()
        let item = try await repos.clonedItem()
        let hook = item.path.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho 'eslint: 3 errors' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try repos.write("a.js", "x\n", in: item.path)
        await item.refresh()

        item.message = "Add a"
        await item.commit()
        let problem = try #require(item.problem)
        #expect(problem.fixes.contains(.showOutput))
        #expect(problem.output.contains("eslint: 3 errors"))
        #expect(item.message == "Add a", "a failed commit keeps the message")
        #expect(item.status?.staged.isEmpty == true)
    }

    @Test func rejectedPushOffersSync() async throws {
        let repos = try await TestRepos()
        let item = try await repos.clonedItem()
        let other = repos.root.appendingPathComponent("other")
        try await repos.git(["clone", "-q", repos.root.appendingPathComponent("app.git").path, other.path], in: repos.root)
        try repos.write("o.txt", "o\n", in: other)
        try await repos.git(["add", "-A"], in: other)
        try await repos.git(["commit", "-q", "-m", "Other"], in: other)
        try await repos.git(["push", "-q"], in: other)

        try repos.write("a.txt", "a\n", in: item.path)
        await item.refresh()
        item.message = "Mine"
        await item.commit(then: .push)
        let problem = try #require(item.problem)
        #expect(problem.fixes.contains(.sync))
        #expect(problem.isWarning)
    }
}

@MainActor
@Suite("App model")
struct AppModelTests {
    private func item(_ name: String, changes: Bool = false, ahead: Int = 0, branch: String = "main") -> RepoItem {
        RepoItem(id: name, name: name, path: URL(fileURLWithPath: "/tmp/\(name)"), status: RepoStatus(
            branch: BranchState(head: branch, oid: "x", upstream: "origin/\(branch)", ahead: ahead),
            unstaged: changes ? [FileChange(path: "f", kind: .modified, area: .unstaged)] : []
        ))
    }

    @Test func entriesSplitActiveAndQuietAndFilter() {
        let app = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!), dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())"))
        let dirty = item("web", changes: true)
        let ahead = item("api", ahead: 2)
        let clean = item("docs")
        app.projects = [ProjectItem(id: "p", name: "Harbor", repos: [dirty, ahead, clean])]

        let attention = app.entries(for: .attention)
        #expect(attention.groups.map(\.urgency) == [.changes, .readyToPush], "changes first, then what's ready to push")
        #expect(attention.repos.map(\.id) == ["web", "api"])
        #expect(attention.group(.clear).isEmpty)
        #expect(attention.entries.first?.projectName == "Harbor")

        let all = app.entries(for: .all)
        #expect(all.group(.clear).map(\.id) == ["docs"])

        let project = app.entries(for: .project("p"))
        #expect(project.entries.first?.projectName == nil)

        app.searchText = "DOC"
        #expect(app.entries(for: .all).group(.clear).map(\.id) == ["docs"])
        #expect(app.entries(for: .all).group(.changes).isEmpty)
        #expect(app.attentionCount == 2)
    }

    @Test func protectedBranchAsksOncePerSessionUnlessSuppressed() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!)
        let app = AppModel(settings: settings, dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())"))
        let repo = item("api", changes: true)
        repo.app = app
        repo.message = "Fix"
        app.projects = [ProjectItem(id: "p", name: "P", repos: [repo])]

        app.requestCommit(repo)
        let confirmation = try? #require(app.confirmation)
        #expect(confirmation?.title == "Commit directly to main?")
        #expect(confirmation?.suppressionRepoID == "api")

        app.confirmation = nil
        settings.protectedBranchConfirmationSkipped.insert("api")
        app.requestCommit(repo)
        #expect(app.confirmation == nil)
    }

    @Test func emptyMessageNeverAsks() {
        let app = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!), dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())"))
        let repo = item("api", changes: true)
        repo.app = app
        app.requestCommit(repo)
        #expect(app.confirmation == nil)
    }

    @Test func manyReposWithChangesCollapseToTheCurrentOne() {
        let app = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!), dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())"))
        let three = (1...3).map { item("r\($0)", changes: true) }
        #expect(app.collapsedRepoIDs(in: three).isEmpty, "up to three stay open")

        let five = (1...5).map { item("r\($0)", changes: true) } + [item("clean", ahead: 1)]
        app.repos = Dictionary(uniqueKeysWithValues: five.map { ($0.id, $0) })
        #expect(app.collapsedRepoIDs(in: five) == ["r2", "r3", "r4", "r5"], "first opens by default; clean repos are never 'collapsed'")

        app.currentRepoID = "r3"
        #expect(!app.collapsedRepoIDs(in: five).contains("r3"))
        #expect(app.collapsedRepoIDs(in: five).contains("r1"))

        // Clicking a clean repo keeps the last opened one open.
        app.currentRepoID = "clean"
        #expect(!app.collapsedRepoIDs(in: five).contains("r3"))

        // Work in progress never collapses.
        five[4].message = "half-typed"
        #expect(!app.collapsedRepoIDs(in: five).contains("r5"))
    }

    @Test func problemMapping() {
        let behind = RepoProblem(GitError(kind: .pushRejectedBehind, command: ["push"], exitCode: 1, stderr: "! [rejected]"))
        #expect(behind.fixes.first == .sync)
        let identity = RepoProblem(GitError(kind: .identityMissing, command: ["commit"], exitCode: 128, stderr: "Please tell me who you are"))
        #expect(identity.fixes.contains(.openSettings))
        #expect(identity.message.contains("Settings"))
    }
}

@MainActor
@Suite("Opening repo files")
struct OpenerTests {
    @Test func neverRunsExecutablesFromARepo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-open-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func file(_ name: String, executable: Bool = false) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            return url
        }
        let noEditor: (String) -> Bool = { _ in false }
        #expect(Opener.openAction(for: try file("run.command", executable: true), editorBundleID: "", editorInstalled: noEditor) == .textEdit)
        #expect(Opener.openAction(for: try file("install.pkg"), editorBundleID: "", editorInstalled: noEditor) == .textEdit)
        #expect(Opener.openAction(for: try file("deploy", executable: true), editorBundleID: "", editorInstalled: noEditor) == .textEdit)
        #expect(Opener.openAction(for: try file("README.md"), editorBundleID: "", editorInstalled: noEditor) == .defaultApp)
        #expect(Opener.openAction(for: dir, editorBundleID: "", editorInstalled: noEditor) == .reveal)
        #expect(Opener.openAction(for: try file("run.command"), editorBundleID: "com.example.editor", editorInstalled: { _ in true }) == .editor)
    }
}
