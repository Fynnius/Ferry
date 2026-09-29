import Foundation
import Testing
@testable import FerryKit

/// `DiscoveredRepo.lastActivity`: stats of the git dir's index and HEAD log, on
/// generated trees in a temp dir.
@Suite("Last activity")
struct LastActivityTests {
    private let longAgo = Date(timeIntervalSince1970: 1_700_000_000) // Nov 2023

    private func setModified(_ date: Date, _ paths: URL...) throws {
        for path in paths {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        }
    }

    @Test func comesFromIndexAndHeadLogNotFetches() async throws {
        let tree = try await FixtureTree.build([.repo(FixtureRepo(name: "app"))])
        let git = tree.url("app").appendingPathComponent(".git")
        try setModified(longAgo, git.appendingPathComponent("index"), git.appendingPathComponent("logs/HEAD"))
        // A fetch writes FETCH_HEAD and HEAD may be rewritten by tools; neither is work.
        try "".write(to: git.appendingPathComponent("FETCH_HEAD"), atomically: true, encoding: .utf8)

        var repo = try #require(await tree.scan([tree.root()]).repos.first)
        #expect(repo.lastActivity == longAgo)

        // Staging something counts.
        try setModified(.now, git.appendingPathComponent("index"))
        repo = try #require(await tree.scan([tree.root()]).repos.first)
        #expect(try #require(repo.lastActivity).timeIntervalSinceNow > -60)
    }

    @Test func worktreesUseTheirOwnGitDir() async throws {
        let tree = try await FixtureTree.build([
            .repo(FixtureRepo(name: "app", worktrees: [FixtureWorktree(path: "../app-feature", branch: "feature")])),
        ])
        let main = tree.url("app").appendingPathComponent(".git")
        try setModified(longAgo, main.appendingPathComponent("index"), main.appendingPathComponent("logs/HEAD"))
        let worktreeDir = main.appendingPathComponent("worktrees/app-feature")
        let recent = Date(timeIntervalSinceNow: -3600).rounded
        try setModified(recent, worktreeDir.appendingPathComponent("index"), worktreeDir.appendingPathComponent("logs/HEAD"))

        let result = await tree.scan([tree.root()])
        let app = try #require(result.repos.first { $0.name == "app" })
        let worktree = try #require(result.repos.first { $0.name == "app-feature" })
        #expect(app.lastActivity == longAgo)
        #expect(worktree.lastActivity == recent)

        // Work in a worktree is work on the repo.
        let entry = RepoEntry(id: RepoID("path:app"), remote: nil, copies: [RepoCopy(repo: app, worktrees: [worktree])])
        #expect(entry.lastActivity == recent)
    }

    @Test func notDownloadedReposAreNeverStatted() async throws {
        let tree = try await FixtureTree.build([.repo(FixtureRepo(name: "evicted", notDownloaded: true))])
        let (scanner, fs) = tree.scanner(readRemotes: false)
        let repo = try #require(await scanner.scan([tree.root()]).repos.first)
        #expect(repo.lastActivity == nil)
        #expect(fs.touchedPlaceholders.isEmpty)
    }

    @Test func scansSavedBeforeTheFieldStillDecode() throws {
        let old = #"{"url":"file:///w/app/","kind":{"repository":{}},"isDownloaded":true}"#
        let repo = try JSONDecoder().decode(DiscoveredRepo.self, from: Data(old.utf8))
        #expect(repo.lastActivity == nil)
        #expect(repo.name == "app")

        let withDate = DiscoveredRepo(url: URL(fileURLWithPath: "/w/app"), lastActivity: longAgo)
        let roundTrip = try JSONDecoder().decode(DiscoveredRepo.self, from: JSONEncoder().encode(withDate))
        #expect(roundTrip.lastActivity == longAgo)
    }
}

private extension Date {
    /// Whole seconds, so a date survives the file system's timestamp precision.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
