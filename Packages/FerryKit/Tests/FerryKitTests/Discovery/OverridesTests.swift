import Foundation
import Testing
@testable import FerryKit

/// Overrides applied to fresh groupings (pure), and their persistence.
@Suite("Overrides and persistence")
struct OverridesTests {
    typealias G = ProjectGrouperTests
    let grouper = ProjectGrouper(homeDirectory: URL(fileURLWithPath: G.home))

    /// Harbor (app, admin, docs) + two repos with no signal.
    static let scan = G.scan([
        G.repo("/code/Harbor/app", "git@github.com:acme/app.git"),
        G.repo("/code/Harbor/admin", "git@github.com:acme/admin.git"),
        G.repo("/code/Harbor/docs", "git@github.com:acme/docs.git"),
        G.repo("/code/notes", "git@github.com:me/notes.git"),
        G.repo("/code/blog"),
    ])
    static let harbor = ProjectID("folder:/code/Harbor")
    static let app = RepoID("github.com/acme/app"), docs = RepoID("github.com/acme/docs"), notes = RepoID("github.com/me/notes")
    static let blog = RepoID("path:/code/blog")

    @Test func noOverridesChangesNothing() {
        let suggested = grouper.group(Self.scan)
        #expect(DiscoveryOverrides().apply(to: suggested) == suggested)
    }

    @Test func renameCreateMovePinHide() {
        var overrides = DiscoveryOverrides()
        overrides.rename(Self.harbor, to: "Harbor Platform")
        let personal = overrides.createProject(named: "Personal", id: ProjectID("user:personal"))
        overrides.move(Self.notes, to: personal)
        overrides.move(Self.blog, to: personal)
        overrides.move(Self.docs, to: .other)
        overrides.setPinned(RepoID("github.com/acme/admin"), true)
        overrides.setHidden(Self.app, true)

        let grouping = grouper.group(Self.scan, overrides: overrides)
        #expect(grouping.projects.map(\.name) == ["Harbor Platform", "Personal"])
        let harbor = grouping.projects[0]
        #expect(harbor.repos.map(\.name) == ["admin"])
        #expect(harbor.repos[0].isPinned)
        let mine = grouping.projects[1]
        #expect(mine.isUserCreated && mine.why == "Created by you")
        #expect(mine.repos.map(\.name) == ["blog", "notes"])
        #expect(mine.repos.allSatisfy { $0.isPlacedByUser })
        #expect(grouping.other.map(\.name) == ["docs"])
        #expect(grouping.hidden.map(\.name) == ["app"])
    }

    @Test func pinnedReposSortFirst() {
        var overrides = DiscoveryOverrides()
        overrides.setPinned(Self.docs, true)
        let harbor = grouper.group(Self.scan, overrides: overrides).projects[0]
        #expect(harbor.repos.map(\.name) == ["docs", "admin", "app"])
    }

    @Test func emptiedSuggestionDisappearsButCreatedProjectStays() {
        var overrides = DiscoveryOverrides()
        overrides.createProject(named: "Later", id: ProjectID("user:later"))
        for repo in ["app", "admin", "docs"] { overrides.setHidden(RepoID("github.com/acme/\(repo)"), true) }
        let grouping = grouper.group(Self.scan, overrides: overrides)
        #expect(grouping.projects.map(\.name) == ["Later"])
    }

    @Test func renameMatchesAnAliasAfterTheStrongestSignalChanges() {
        var overrides = DiscoveryOverrides()
        overrides.rename(Self.harbor, to: "Harbor Platform")
        // Rescan now also finds a workspace file; the project's id becomes the workspace's.
        let rescan = G.scan(Self.scan.repos, workspaces: [G.workspace("/code/Harbor/H.code-workspace", ["/code/Harbor/app", "/code/Harbor/admin"])])
        let project = grouper.group(rescan, overrides: overrides).projects[0]
        #expect(project.id == ProjectID("workspace:/code/Harbor/H.code-workspace"))
        #expect(project.name == "Harbor Platform")
    }

    @Test func overridesForVanishedThingsAreIgnored() {
        var overrides = DiscoveryOverrides()
        overrides.move(Self.app, to: ProjectID("folder:/gone"))
        overrides.setHidden(RepoID("github.com/acme/deleted"), true)
        overrides.rename(ProjectID("folder:/gone"), to: "Ghost")
        overrides.choosePrimaryCopy(URL(fileURLWithPath: "/nowhere/app"), for: Self.app)
        let grouping = grouper.group(Self.scan, overrides: overrides)
        #expect(grouping == grouper.group(Self.scan))
    }

    @Test func choosePrimaryCopyAmongDuplicates() {
        let scan = G.scan([
            G.repo("/one/app", "git@github.com:acme/app.git"),
            G.repo("/two/app", "git@github.com:acme/app.git"),
        ], roots: ["/one", "/two"])
        #expect(grouper.group(scan).visibleRepos[0].primary.url.path == "/one/app")
        var overrides = DiscoveryOverrides()
        overrides.choosePrimaryCopy(URL(fileURLWithPath: "/two/app"), for: Self.app)
        let entry = grouper.group(scan, overrides: overrides).visibleRepos[0]
        #expect(entry.primary.url.path == "/two/app")
        #expect(entry.copies.count == 2)
    }

    @Test func notRelatedSurvivesRescans() {
        var overrides = DiscoveryOverrides()
        overrides.markNotRelated(Self.docs, Self.app)
        let grouping = grouper.group(Self.scan, overrides: overrides)
        let harbor = grouping.project(containing: Self.app)
        #expect(harbor?.repos.contains { $0.id == Self.docs } == false)
        #expect(grouping.other.contains { $0.id == Self.docs })
    }

    // MARK: Store

    private func tempStore() -> DiscoveryStore {
        DiscoveryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-store-\(UUID().uuidString.prefix(8))/Ferry", isDirectory: true))
    }

    @Test func settingsRoundTripAsReadableJSON() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        var settings = DiscoverySettings(roots: [ScanRoot(url: URL(fileURLWithPath: "/code"), maxDepth: 4)])
        settings.overrides.rename(Self.harbor, to: "Harbor Platform")
        settings.overrides.move(Self.notes, to: .other)
        settings.overrides.markNotRelated(Self.app, Self.docs)
        settings.overrides.setPinned(Self.app, true)
        settings.overrides.addManualRepo(URL(fileURLWithPath: "/elsewhere/tool"))
        settings.overrides.choosePrimaryCopy(URL(fileURLWithPath: "/two/app"), for: Self.app)
        try store.save(settings)

        #expect(store.loadSettings() == settings)
        let json = try String(contentsOf: store.settingsURL, encoding: .utf8)
        #expect(json.contains("\"folder:/code/Harbor\" : \"Harbor Platform\""))
        #expect(json.contains("\"github.com/me/notes\" : \"other\""))
    }

    @Test func missingFileGivesDefaults() {
        #expect(tempStore().loadSettings() == DiscoverySettings())
    }

    @Test func unreadableFileIsMovedAsideNotLost() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try "{ not json".write(to: store.settingsURL, atomically: true, encoding: .utf8)
        #expect(store.loadSettings() == DiscoverySettings())
        let aside = store.directory.appendingPathComponent("discovery.json.unreadable")
        #expect((try String(contentsOf: aside, encoding: .utf8)) == "{ not json")
    }

    @Test func olderFilesWithMissingFieldsStillLoad() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try #"{"roots":[{"url":"file:///code/","maxDepth":3}],"overrides":{"hidden":["path:/code/blog"]}}"#
            .write(to: store.settingsURL, atomically: true, encoding: .utf8)
        let settings = store.loadSettings()
        #expect(settings.roots.map(\.maxDepth) == [3])
        #expect(settings.overrides.hidden == [Self.blog])
        #expect(settings.overrides.assignments.isEmpty)
    }

    @Test func manualReposAreScannedAsDepthZeroRoots() {
        var settings = DiscoverySettings(roots: [ScanRoot(url: URL(fileURLWithPath: "/code"))])
        settings.overrides.addManualRepo(URL(fileURLWithPath: "/elsewhere/tool"))
        settings.overrides.addManualRepo(URL(fileURLWithPath: "/elsewhere/tool"))
        #expect(settings.scanRoots.map(\.maxDepth) == [ScanRoot.defaultMaxDepth, 0])
        #expect(settings.scanRoots.last?.url.path == "/elsewhere/tool")
    }

    @Test func lastScanRoundTrips() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        #expect(store.loadLastScan() == nil)
        let scan = G.scan([
            G.repo("/code/app", "git@github.com:acme/app.git"),
            G.repo("/code/app-wt", nil, kind: .worktree(parent: directoryURL("/code/app"), branch: "x")),
        ])
        try store.saveLastScan(scan)
        #expect(store.loadLastScan() == scan)
    }
}

/// What a rescan reports.
@Suite("Rescan diff")
struct ScanDiffTests {
    typealias G = ProjectGrouperTests

    @Test func firstScanAnnouncesNothingButReportsDuplicates() {
        let scan = G.scan([G.repo("/a/app", "git@github.com:acme/app.git"), G.repo("/b/app", "https://github.com/acme/app")])
        let diff = ScanDiff(from: nil, to: scan)
        #expect(diff.isEmpty)
        #expect(diff.duplicates[RepoID("github.com/acme/app")]?.map(\.path) == ["/a/app", "/b/app"])
    }

    @Test func newRepoNewCopyMoveAndRemoval() {
        let old = G.scan([
            G.repo("/code/app", "git@github.com:acme/app.git"),
            G.repo("/code/api", "git@github.com:acme/api.git"),
            G.repo("/code/scratch"),
        ])
        let new = G.scan([
            G.repo("/code/app", "git@github.com:acme/app.git"),
            G.repo("/code/backup/app", "git@github.com:acme/app.git"), // cloned again
            G.repo("/code/services/api", "git@github.com:acme/api.git"), // moved
            G.repo("/code/web", "git@github.com:acme/web.git"), // new
            G.repo("/code/web-wt", nil, kind: .worktree(parent: directoryURL("/code/web"), branch: "x")),
            // scratch deleted
        ])
        let diff = ScanDiff(from: old, to: new)
        #expect(diff.newRepos.map(\.path) == ["/code/web"])
        #expect(diff.newCopies.map(\.path) == ["/code/backup/app"])
        #expect(diff.moved == [ScanDiff.Move(id: RepoID("github.com/acme/api"), from: directoryURL("/code/api"), to: directoryURL("/code/services/api"))])
        #expect(diff.removed.map(\.path) == ["/code/scratch"])
        #expect(diff.duplicates.keys.map(\.rawValue) == ["github.com/acme/app"])
    }

    @Test func reposOnAnUnreadableRootAreUnavailableNotRemoved() {
        let old = G.scan([G.repo("/Volumes/Work/app"), G.repo("/code/gone")], roots: ["/Volumes/Work", "/code"])
        var new = G.scan([], roots: ["/Volumes/Work", "/code"])
        new.unreadableRoots = [directoryURL("/Volumes/Work")]
        #expect(ScanDiff(from: old, to: new).removed.map(\.path) == ["/code/gone"])
    }

    @Test func cancelledScanRemovesNothing() {
        let old = G.scan([G.repo("/code/app"), G.repo("/code/api")])
        var new = G.scan([G.repo("/code/app")])
        new.wasCancelled = true
        #expect(ScanDiff(from: old, to: new).removed.isEmpty)
    }
}
