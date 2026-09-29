import Foundation
import Testing
@testable import Ferry
import FerryKit

@MainActor
@Suite("Next repo that needs you")
struct NavigationTests {
    private func makeApp() -> AppModel {
        AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!), dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())"))
    }

    private func item(_ name: String, changes: Bool = false, ahead: Int = 0) -> RepoItem {
        RepoItem(id: name, name: name, path: URL(fileURLWithPath: "/tmp/\(name)"), status: RepoStatus(
            branch: BranchState(head: "main", oid: "x", upstream: "origin/main", ahead: ahead),
            unstaged: changes ? [FileChange(path: "f", kind: .modified, area: .unstaged)] : []
        ))
    }

    @Test func nextAndPreviousWrapAndSkipQuietRepos() {
        let app = makeApp()
        let a = item("a", changes: true), b = item("b"), c = item("c", ahead: 1), d = item("d", changes: true)
        app.projects = [ProjectItem(id: "p", name: "P", repos: [a, b, c, d])]
        app.selection = .all

        #expect(app.repoNeedingYou(step: 1)?.id == "a", "nothing current: start at the top")
        #expect(app.repoNeedingYou(step: -1)?.id == "d", "…or at the bottom going back")
        app.currentRepoID = "a"
        #expect(app.repoNeedingYou(step: 1)?.id == "c", "b is up to date")
        app.currentRepoID = "d"
        #expect(app.repoNeedingYou(step: 1)?.id == "a", "wraps around")
        #expect(app.repoNeedingYou(step: -1)?.id == "c")
        app.currentRepoID = "b"
        #expect(app.repoNeedingYou(step: 1)?.id == "a", "quiet repos sit at the bottom of the stack, so next wraps to the top")
        #expect(app.repoNeedingYou(step: -1)?.id == "d")

        app.projects = [ProjectItem(id: "p", name: "P", repos: [a, b])]
        app.currentRepoID = "a"
        #expect(app.repoNeedingYou(step: 1)?.id == "a", "the only one left is the current one")
        a.status = b.status
        #expect(app.repoNeedingYou(step: 1) == nil)
    }

    @Test func focusGoesToTheMessageFieldOrTheCard() {
        let app = makeApp()
        let dirty = item("dirty", changes: true), ahead = item("ahead", ahead: 2)
        app.projects = [ProjectItem(id: "p", name: "P", repos: [dirty, ahead])]
        app.repos = ["dirty": dirty, "ahead": ahead]

        app.goToRepoNeedingYou(step: 1)
        #expect(app.currentRepoID == "dirty")
        #expect(app.scrollTarget == "dirty")
        #expect(app.openRepoID == "dirty", "a collapsed repo opens")
        #expect(dirty.focusMessageCount == 1)

        app.goToRepoNeedingYou(step: 1)
        #expect(app.currentRepoID == "ahead")
        #expect(app.focusCardRequest == "ahead")
        #expect(ahead.focusMessageCount == 0)
    }

    @Test func movesOnOnlyWhenTheRepoIsDone() async throws {
        let repos = try await TestRepos()
        let app = makeApp()
        let x = try await repos.clonedItem("x", app: app)
        let y = try await repos.clonedItem("y", app: app)
        app.projects = [ProjectItem(id: "p", name: "P", repos: [x, y])]
        app.repos = [x.id: x, y.id: y]
        for repo in [x, y] {
            try repos.write("a.txt", "a\n", in: repo.path)
            await repo.refresh()
        }

        // A plain commit leaves a push to do: stay, so ⌥⌘P still pushes x.
        app.currentRepoID = x.id
        x.message = "First"
        await x.commit()
        #expect(app.currentRepoID == x.id)

        // Pushing finishes x: move to y, cursor in its message field.
        await x.push()
        #expect(app.currentRepoID == y.id)
        #expect(y.focusMessageCount >= 1)

        // Commit & Push in y with x clean: nothing else needs you, so stay.
        y.message = "Second"
        await y.commit(then: .push)
        #expect(y.status?.needsAttention == false)
        #expect(app.currentRepoID == y.id)
    }

    @Test func neverMovesAwayFromARepoTheUserLeft() async throws {
        let repos = try await TestRepos()
        let app = makeApp()
        let x = try await repos.clonedItem("x", app: app)
        let y = try await repos.clonedItem("y", app: app)
        let z = try await repos.clonedItem("z", app: app)
        app.projects = [ProjectItem(id: "p", name: "P", repos: [x, y, z])]
        for repo in [x, y, z] {
            try repos.write("a.txt", "a\n", in: repo.path)
            await repo.refresh()
        }
        // The user clicked into z while x was committing and pushing.
        app.currentRepoID = z.id
        x.message = "Mine"
        await x.commit(then: .push)
        #expect(app.currentRepoID == z.id)
        #expect(y.focusMessageCount == 0)
    }
}
