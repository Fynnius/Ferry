import Foundation
import Testing
@testable import Ferry
import FerryKit

/// Folders dropped on the window or Dock icon, or sent by Finder's Open in Ferry service.
/// Temp folders only; never the user's repos or saved settings.
@MainActor
@Suite("Dropped folders")
struct FolderDropTests {
    @Test func classifiesReposFoldersAndEverythingElse() throws {
        let repos = try TempTree()
        let repo = try repos.folder("repo/.git")
        let worktree = try repos.file("worktree/.git", "gitdir: /elsewhere/.git/worktrees/w\n")
        let plain = try repos.folder("plain")
        let file = try repos.file("notes.txt", "x")
        let package = try repos.folder("Tool.app/Contents")

        #expect(DroppedFolder.classify(repo.deletingLastPathComponent()) == .repository(repo.deletingLastPathComponent()))
        #expect(DroppedFolder.classify(worktree.deletingLastPathComponent()) == .repository(worktree.deletingLastPathComponent()))
        #expect(DroppedFolder.classify(plain) == .root(plain))
        #expect(DroppedFolder.classify(file) == nil)
        #expect(DroppedFolder.classify(package.deletingLastPathComponent()) == nil)
        #expect(DroppedFolder.classify(repos.root.appendingPathComponent("missing")) == nil)
        #expect(DroppedFolder.classify(URL(string: "https://example.com")!) == nil)
    }

    @Test func pathsCompareThroughSymlinks() throws {
        // The temp folder lives under /var, a symlink to /private/var; Finder and the
        // scanner may disagree on which form they report.
        let tree = try TempTree()
        let a = try tree.folder("a/b")
        let viaPrivate = URL(fileURLWithPath: "/private" + tree.root.path)
        #expect(tree.root.path.hasPrefix("/var/"))
        #expect(AppModel.samePath(tree.root, viaPrivate))
        #expect(AppModel.isInside(a, viaPrivate))
        #expect(!AppModel.isInside(try tree.folder("ab"), tree.root.appendingPathComponent("a")))
    }

    /// The whole path: waits through onboarding, then a repo becomes a manual repo, a known
    /// repo is just shown, and an empty folder becomes a root with a notice.
    @Test func droppedFoldersAreAddedAndShown() async throws {
        let git = try await TestRepos()
        let projects = git.root.appendingPathComponent("projects")
        for name in ["projects/alpha", "projects/beta", "solo"] {
            try await git.git(["init", "-q", git.root.appendingPathComponent(name).path], in: git.root)
        }
        let empty = git.root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let solo = git.root.appendingPathComponent("solo")

        let app = AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!),
            dataDirectory: git.root.appendingPathComponent("data")
        )
        await app.start()
        #expect(app.phase == .onboarding)

        // Not folders: refused. During onboarding folders wait for the onboarding view.
        #expect(!app.openFolders([git.root.appendingPathComponent("gitconfig")]))
        #expect(app.openFolders([solo]))
        #expect(app.droppedFolders == [solo.standardizedFileURL])
        app.droppedFolders = []

        app.addRoots([projects])
        try await waitUntil { app.phase == .ready && !app.isScanning && app.allRepos.count == 2 }

        app.openFolders([solo])
        try await waitUntil { app.currentRepo.map { AppModel.samePath($0.path, solo) } == true }
        #expect(app.discovery.overrides.manualRepos.contains { AppModel.samePath($0, solo) })
        #expect(app.allRepos.count == 3)
        #expect(app.scrollTarget == app.currentRepoID)
        if case .project(let id) = app.selection {
            #expect(app.projects.first { $0.id == id }?.repos.contains { $0.id == app.currentRepoID } == true)
        } else {
            Issue.record("expected the repo's project to be selected, got \(String(describing: app.selection))")
        }

        // Already known: nothing is added, it's just shown.
        let alpha = projects.appendingPathComponent("alpha")
        app.openFolders([alpha])
        try await waitUntil { app.currentRepo.map { AppModel.samePath($0.path, alpha) } == true }
        #expect(app.discovery.overrides.manualRepos.count == 1)
        #expect(app.discovery.roots.count == 1)

        // A folder without repos: kept as a root (repos cloned there later show up), and said so.
        app.openFolders([empty])
        try await waitUntil { app.fleetNotice?.contains("No git repositories") == true }
        #expect(app.discovery.roots.map(\.url).contains { AppModel.samePath($0, empty) })
    }

    private func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// A throwaway folder tree, removed when the test ends.
private final class TempTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-drop-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func file(_ path: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
