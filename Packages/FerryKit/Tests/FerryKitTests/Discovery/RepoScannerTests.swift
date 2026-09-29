import Foundation
import Testing
@testable import FerryKit

/// The scanner on generated trees in a temp dir; never on this Mac's real folders.
@Suite("Repo scanner")
struct RepoScannerTests {
    @Test func findsReposAndReadsRemotes() async throws {
        let tree = try await FixtureTree.build([
            .dir("Harbor", [
                .repo(FixtureRepo(name: "harbor-app", remoteURL: "git@github.com:acme/harbor-app.git")),
                .repo(FixtureRepo(name: "harbor-admin", remoteURL: "https://github.com/acme/harbor-admin")),
            ]),
            .repo(FixtureRepo(name: "notes")),
        ])
        let result = await tree.scan([tree.root()])
        #expect(result.repos.map(\.name) == ["harbor-admin", "harbor-app", "notes"])
        #expect(result.repos.map(\.remoteURL) == ["https://github.com/acme/harbor-admin", "git@github.com:acme/harbor-app.git", nil])
        #expect(result.repos.allSatisfy { $0.kind == .repository && $0.isDownloaded })
        #expect(result.repos[1].url == tree.url("Harbor/harbor-app"))
        #expect(!result.wasCancelled)
    }

    @Test func remoteURLHonoursInsteadOf() async throws {
        let tree = try await FixtureTree.build(
            [.repo(FixtureRepo(name: "app", remoteURL: "gh:acme/app.git"))],
            extraGitConfig: "[url \"git@github.com:\"]\n    insteadOf = gh:"
        )
        let result = await tree.scan([tree.root()])
        #expect(result.repos.first?.remoteURL == "git@github.com:acme/app.git")
    }

    @Test func prunesDependencyAndBuildFolders() async throws {
        let tree = try await FixtureTree.build([
            .dir("web", [
                .dir("node_modules", [.repo(FixtureRepo(name: "left-pad"))]),
                .dir("build", [.repo(FixtureRepo(name: "generated"))]),
                .dir(".cache", [.repo(FixtureRepo(name: "cached"))]),
                .dir(".parcel-cache", [.repo(FixtureRepo(name: "parcel"))]),
                .dir("Tool.app", [.repo(FixtureRepo(name: "bundled"))]),
                .repo(FixtureRepo(name: "real")),
            ]),
            .dir("Library", [.repo(FixtureRepo(name: "in-home-library"))]),
            .dir("Work", [.dir("Library", [.repo(FixtureRepo(name: "not-home-library"))])]),
        ])
        let (scanner, fs) = tree.scanner(readRemotes: false)
        let result = await scanner.scan([tree.root()])
        #expect(result.repos.map(\.name) == ["not-home-library", "real"])
        #expect(!fs.listed.contains { $0.contains("node_modules") || $0.hasSuffix("/Library") && !$0.contains("Work") })
    }

    @Test func respectsMaxDepthPerRoot() async throws {
        let tree = try await FixtureTree.build([
            .dir("a", [.dir("b", [.repo(FixtureRepo(name: "deep"))])]),
        ])
        // deep sits 3 levels below the root: a/b/deep.
        #expect(await tree.scan([tree.root(maxDepth: 3)]).repos.map(\.name) == ["deep"])
        #expect(await tree.scan([tree.root(maxDepth: 2)]).repos.isEmpty)
        #expect(await tree.scan([tree.root("a/b/deep", maxDepth: 0)]).repos.map(\.name) == ["deep"])
    }

    @Test func stopsAtRepoRootsSoNestedReposStayInside() async throws {
        let tree = try await FixtureTree.build([
            .repo(FixtureRepo(name: "outer", files: ["tools/.keep": ""])),
        ])
        // A repo cloned inside another's working tree (not a submodule).
        try await tree.fixture.git(["init", "-q", tree.url("outer/tools/inner").path], in: tree.base)
        let result = await tree.scan([tree.root()])
        #expect(result.repos.map(\.name) == ["outer"])
    }

    @Test func bareReposAreReportedNotListed() async throws {
        let tree = try await FixtureTree.build([
            .repo(FixtureRepo(name: "mirror.git", bare: true)),
            .repo(FixtureRepo(name: "app")),
        ])
        let result = await tree.scan([tree.root()])
        #expect(result.repos.map(\.name) == ["app"])
        #expect(result.bareRepositories == [tree.url("mirror.git")])
    }

    @Test func overlappingRootsReportEachRepoOnce() async throws {
        let tree = try await FixtureTree.build([.dir("Harbor", [.repo(FixtureRepo(name: "app"))])])
        let result = await tree.scan([tree.root(), tree.root("Harbor")])
        #expect(result.repos.count == 1)
    }

    @Test func unreadableFoldersAreSkippedSilently() async throws {
        let tree = try await FixtureTree.build([
            .dir("locked", [.repo(FixtureRepo(name: "hidden-away"))]),
            .repo(FixtureRepo(name: "app")),
        ])
        let locked = tree.url("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            withExtendedLifetime(tree) {} // Clean-up must run after permissions are restored.
        }

        let result = await tree.scan([tree.root(), ScanRoot(url: tree.url("gone")), tree.root("locked")])
        #expect(result.repos.map(\.name) == ["app"])
        #expect(result.unreadableRoots.map(\.lastPathComponent) == ["gone", "locked"])
    }

    @Test func cloudPlaceholdersAreNeverOpened() async throws {
        let tree = try await FixtureTree.build([
            .repo(FixtureRepo(name: "evicted", remoteURL: "git@github.com:acme/evicted.git", notDownloaded: true)),
            .iCloudPlaceholder(name: "Archive"),
            .repo(FixtureRepo(name: "local")),
        ])
        let (scanner, fs) = tree.scanner()
        let result = await scanner.scan([tree.root()])

        let evicted = try #require(result.repos.first { $0.name == "evicted" })
        #expect(!evicted.isDownloaded)
        #expect(evicted.remoteURL == nil) // git never ran in it
        #expect(result.repos.first { $0.name == "local" }?.isDownloaded == true)
        #expect(result.notDownloadedFolders == [tree.url("Archive")])
        #expect(fs.touchedPlaceholders.isEmpty)
    }

    @Test func cancellationStopsBetweenFolders() async throws {
        let tree = try await FixtureTree.build([
            .dir("a", [.repo(FixtureRepo(name: "first"))]),
            .dir("b", [.repo(FixtureRepo(name: "second"))]),
        ])
        let (scanner, fs) = tree.scanner(readRemotes: false)
        // Cancel the scanning task the moment it enters b/ (the walk is depth-first, a/ before b/).
        fs.onList.withLock { $0 = { url in
            if url.lastPathComponent == "b" { withUnsafeCurrentTask { $0?.cancel() } }
        } }
        let result = await Task { await scanner.scan([tree.root()]) }.value
        #expect(result.wasCancelled)
        #expect(result.repos.map(\.name) == ["first"])
    }

    @Test func eventsStreamFoundReposThenFinished() async throws {
        let tree = try await FixtureTree.build([
            .repo(FixtureRepo(name: "one", remoteURL: "git@github.com:acme/one.git")),
            .repo(FixtureRepo(name: "two")),
        ])
        var found: [DiscoveredRepo] = []
        var finished: ScanResult?
        for await event in tree.scanner().0.events(for: [tree.root()]) {
            switch event {
            case .found(let repo): found.append(repo)
            case .finished(let result): finished = result
            case .progress, .foundBareRepository: break
            }
        }
        #expect(found.map(\.name).sorted() == ["one", "two"])
        #expect(found.first { $0.name == "one" }?.remoteURL == "git@github.com:acme/one.git")
        #expect(finished?.repos.count == 2)
    }

    @Test func sixtyReposScanWarmInUnderASecond() async throws {
        let projects = (0..<12).map { p in
            FixtureNode.dir("Project\(p)", (0..<5).map { r in
                .repo(FixtureRepo(name: "repo-\(r)", remoteURL: "git@github.com:org\(p)/repo-\(r).git", files: ["node_modules/x/index.js": "", "src/main.swift": ""]))
            })
        }
        let tree = try await FixtureTree.build(projects)
        let (scanner, _) = tree.scanner()
        _ = await scanner.scan([tree.root()]) // Warm file-system caches and the git binary.
        let clock = ContinuousClock()
        var result = ScanResult()
        let elapsed = await clock.measure { result = await scanner.scan([tree.root()]) }
        #expect(result.repos.count == 60)
        #expect(result.repos.allSatisfy { $0.remoteURL != nil })
        #expect(elapsed < .seconds(1), "warm scan of 60 repos took \(elapsed)")
    }
}
