import Foundation
import Testing
@testable import Ferry
import FerryKit

@MainActor
@Suite("The stack: groups, worktrees, folding")
struct StackTests {
    private func makeApp() -> AppModel {
        AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!), dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())"))
    }

    private func item(_ name: String, branch: String = "main", changes: Bool = false, ahead: Int = 0, behind: Int = 0, edited: Date? = nil) -> RepoItem {
        let item = RepoItem(id: name, name: name, path: URL(fileURLWithPath: "/tmp/\(name)"), status: RepoStatus(
            branch: BranchState(head: branch, oid: "x", upstream: "origin/\(branch)", ahead: ahead, behind: behind),
            unstaged: changes ? [FileChange(path: "f", kind: .modified, area: .unstaged)] : []
        ))
        item.lastEditedAt = edited
        return item
    }

    private let longAgo = Date.now.addingTimeInterval(-RepoItem.dormantAfter - 86_400)

    @Test func updatesAndDormantGetTheirOwnGroups() {
        let app = makeApp()
        let web = item("web", changes: true, edited: .now)
        let docs = item("docs", behind: 34)
        let old = item("old", changes: true, edited: longAgo)
        let clean = item("clean")
        app.projects = [ProjectItem(id: "p", name: "P", repos: [clean, old, docs, web])]

        let attention = app.entries(for: .attention)
        #expect(attention.group(.changes).map(\.id) == ["web"])
        #expect(attention.group(.behind).map(\.id) == ["docs"])
        #expect(attention.group(.dormant).map(\.id) == ["old"])
        #expect(attention.group(.clear).isEmpty)
        #expect(app.attentionCount == 1, "updates and dormant work don't count")

        let all = app.entries(for: .all)
        #expect(all.repos.map(\.id) == ["web", "docs", "old", "clean"])
        #expect(app.collapsedRepoIDs(in: all.repos) == ["old"], "dormant repos start folded")
    }

    @Test func worktreesAreRowsOnlyWhileTheyHaveWork() {
        let app = makeApp()
        let mobile = item("mobile")
        let shell = item("wt_3f2a9c1b-89e-1", branch: "feat/home-shell", changes: true)
        let lists = item("wt_7d4e8a2c-12f-2", branch: "feat/lists")
        let parked = RepoItem(id: "wf_parked", name: "wf_parked", path: URL(fileURLWithPath: "/tmp/wf_parked"), status: RepoStatus(branch: BranchState(head: "feat/parked", oid: "x")))
        for worktree in [shell, lists, parked] { worktree.worktreeOf = mobile.id }
        let other = item("other", ahead: 1)
        app.projects = [ProjectItem(id: "p", name: "P", repos: [mobile, shell, lists, parked, other])]
        app.repos = Dictionary(uniqueKeysWithValues: app.allRepos.map { ($0.id, $0) })

        #expect(parked.urgency == .clear, "a worktree's unpublished branch is parked, not a to-do")
        let attention = app.entries(for: .attention)
        #expect(attention.repos.map(\.id) == [shell.id, "other"], "the parent isn't dragged in; clean worktrees have no row")
        #expect(app.entries(for: .all).repos.map(\.id) == [shell.id, "other", "mobile"])
        #expect(app.worktrees(of: mobile).count == 3, "all are in the parent's worktrees menu")

        app.searchText = "home-shell"
        #expect(app.entries(for: .all).repos.map(\.id) == [shell.id], "a worktree's branch finds it")
    }

    @Test func theUsersOpenAndFoldWinOverTheAccordion() {
        let app = makeApp()
        let five = (1...5).map { item("r\($0)", changes: true) }
        app.repos = Dictionary(uniqueKeysWithValues: five.map { ($0.id, $0) })
        #expect(app.collapsedRepoIDs(in: five) == ["r2", "r3", "r4", "r5"])

        app.setFolded(five[3], false)
        #expect(app.currentRepoID == "r4")
        app.currentRepoID = "r1"
        #expect(!app.collapsedRepoIDs(in: five).contains("r4"), "opened on purpose stays open")

        five[0].message = "half-typed"
        app.setFolded(five[0], true)
        #expect(app.collapsedRepoIDs(in: five).contains("r1"), "folded on purpose, even current with a draft")
        #expect(five[0].message == "half-typed", "folding loses nothing")

        let few = Array(five.prefix(2))
        #expect(app.collapsedRepoIDs(in: few) == ["r1"], "a fold holds below the accordion's limit too")
    }

    @Test func aFoldEndsWhenTheRepoIsClean() async throws {
        let repos = try await TestRepos()
        let app = makeApp()
        let repo = try await repos.clonedItem("x", app: app)
        try repos.write("a.txt", "a\n", in: repo.path)
        await repo.refresh()
        app.setFolded(repo, true)

        repo.message = "Add a"
        await repo.commit()
        #expect(app.userFolded[repo.id] == nil)
    }
}

@MainActor
@Suite("Run setup again")
struct RunSetupAgainTests {
    @Test func forgetsFoldersAndOrganisingButKeepsPreferences() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!)
        settings.fetchIntervalMinutes = 10
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())")
        let app = AppModel(settings: settings, dataDirectory: dir)
        app.discovery.roots = [ScanRoot(url: URL(fileURLWithPath: "/tmp/code"))]
        app.discovery.overrides.setHidden(RepoID("x"), true)
        app.saveDiscovery()
        #expect(FileManager.default.fileExists(atPath: app.fleetStore.settingsURL.path))
        app.projects = [ProjectItem(id: "p", name: "P", repos: [RepoItem(id: "r", name: "r", path: URL(fileURLWithPath: "/tmp/r"))])]
        app.phase = .ready

        app.runSetupAgain()
        #expect(app.phase == .onboarding)
        #expect(app.discovery.roots.isEmpty)
        #expect(app.discovery.overrides.hidden.isEmpty)
        #expect(app.projects.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: app.fleetStore.settingsURL.path))
        #expect(app.settings.fetchIntervalMinutes == 10, "preferences stay")
    }
}
