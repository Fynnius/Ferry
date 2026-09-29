import Foundation
import Testing
@testable import FerryKit

/// The nine canonical discovery scenarios, end to end: a real generated tree →
/// scan (real FileManager, real git) → grouping. Each encodes a trap found on a real
/// Mac, rebuilt with neutral names.
private func gh(_ owner: String, _ name: String) -> String { "git@github.com:\(owner)/\(name).git" }

@Suite("Discovery scenarios")
struct DiscoveryScenarioTests {
    /// Scan + group with the tree standing in for the home folder.
    static func discover(_ tree: FixtureTree, roots: [ScanRoot]) async -> (ScanResult, Grouping) {
        let scan = await tree.scan(roots)
        return (scan, ProjectGrouper(homeDirectory: tree.base).group(scan))
    }

    // 1.
    @Test func multiRepoProductWithWorkspaceFile() async throws {
        let tree = try await FixtureTree.build([.dir("Code", [
            .dir("Harbor", [
                .repo(FixtureRepo(name: "harbor-app", remoteURL: gh("acme", "harbor-app"))),
                .repo(FixtureRepo(name: "harbor-admin", remoteURL: gh("acme", "harbor-admin"))),
                .repo(FixtureRepo(name: "harbor-docs", remoteURL: gh("acme", "harbor-docs"))),
                .workspaceFile(FixtureWorkspaceFile(name: "Harbor.code-workspace", folderRefs: ["harbor-app", "harbor-admin", "harbor-docs", "../Shared/brand-kit"])),
            ]),
            // Named by the workspace although it lives elsewhere and has another owner.
            .dir("Shared", [.repo(FixtureRepo(name: "brand-kit", remoteURL: gh("studio", "brand-kit")))]),
        ])])
        let (scan, grouping) = await Self.discover(tree, roots: [tree.root("Code")])
        #expect(scan.workspaceFiles.count == 1)
        #expect(grouping.projects.count == 1)
        let harbor = try #require(grouping.projects.first)
        #expect(harbor.name == "Harbor")
        #expect(harbor.why == "From Harbor.code-workspace")
        #expect(harbor.repos.map(\.name) == ["brand-kit", "harbor-admin", "harbor-app", "harbor-docs"])
    }

    // 2.
    @Test func duplicateClonesAcrossRoots() async throws {
        let names = ["harbor-app", "harbor-admin"]
        let tree = try await FixtureTree.build([
            .dir("Documents", [.dir("Harbor", names.map { .repo(FixtureRepo(name: $0, remoteURL: "https://github.com/Acme/\($0)")) })]),
            .dir("Developer", [.dir("Harbor", (names + ["harbor-mobile"]).map { .repo(FixtureRepo(name: $0, remoteURL: gh("acme", $0))) })]),
        ])
        let (scan, grouping) = await Self.discover(tree, roots: [tree.root("Documents"), tree.root("Developer")])
        #expect(scan.repos.count == 5)
        #expect(grouping.projects.count == 1)
        let harbor = grouping.projects[0]
        #expect(harbor.repos.map(\.name) == ["harbor-admin", "harbor-app", "harbor-mobile"])
        let app = try #require(harbor.repos.first { $0.name == "harbor-app" })
        #expect(app.copies.count == 2)
        // The fuller tree is the default primary copy.
        #expect(app.primary.url == tree.url("Developer/Harbor/harbor-app"))
        #expect(ScanDiff(from: nil, to: scan).duplicates.count == 2)
    }

    // 3.
    @Test func sameNameNoSharedRemote() async throws {
        let tree = try await FixtureTree.build([.dir("Code", [
            .dir("Harbor", [
                .repo(FixtureRepo(name: "harbor-app", remoteURL: gh("acme", "harbor-app"))),
                .repo(FixtureRepo(name: "harbor-admin", remoteURL: gh("acme", "harbor-admin"))),
            ]),
            .dir("Nightly", [.repo(FixtureRepo(name: "harbor-app", files: [".cursor/rules": "x"]))]),
        ])])
        let (_, grouping) = await Self.discover(tree, roots: [tree.root("Code")])
        let harbor = try #require(grouping.projects.first { $0.name == "Harbor" })
        #expect(harbor.repos.map(\.name) == ["harbor-admin", "harbor-app"])
        #expect(!harbor.repos.contains { $0.hasDuplicates })
        #expect(grouping.other.map(\.primary.url) == [tree.url("Code/Nightly/harbor-app")])
    }

    // 4.
    @Test func emptyLookalikeFolder() async throws {
        let tree = try await FixtureTree.build([
            .dir("Harbor", [.repo(FixtureRepo(name: "harbor-admin", remoteURL: gh("acme", "harbor-admin")))]),
            .dir("Market", [.plainFolder(FixturePlainFolder(name: "harbor-admin"))]),
        ])
        let (scan, grouping) = await Self.discover(tree, roots: [tree.root()])
        #expect(scan.repos.map(\.url) == [tree.url("Harbor/harbor-admin")])
        #expect(grouping.visibleRepos.count == 1)
    }

    // 5.
    @Test func staleWorkspaceFile() async throws {
        let tree = try await FixtureTree.build([
            .dir("Ledger", [
                .plainFolder(FixturePlainFolder(name: "src", looseFiles: ["main.py": "print(1)\n"])),
                .workspaceFile(FixtureWorkspaceFile(name: "Ledger.code-workspace", folderRefs: [".", "../Ledger2"])),
            ]),
            .dir("Vision", [.workspaceFile(FixtureWorkspaceFile(name: "Vision.code-workspace", folderRefs: [".", "../beacon"]))]),
            .repo(FixtureRepo(name: "beacon", remoteURL: gh("me", "beacon"))),
        ])
        let (scan, grouping) = await Self.discover(tree, roots: [tree.root()])
        #expect(scan.workspaceFiles.map(\.name) == ["Ledger", "Vision"])
        #expect(scan.repos.map(\.name) == ["beacon"])
        #expect(grouping.projects.isEmpty)
        #expect(grouping.other.map(\.name) == ["beacon"])
    }

    // 6.
    @Test func falsePositiveMonorepoMarkerVsRealMonorepo() async throws {
        let tree = try await FixtureTree.build([
            .repo(FixtureRepo(name: "harbor-web", remoteURL: gh("acme", "harbor-web"), monorepo: .pnpm(hasRealPackages: false))),
            .repo(FixtureRepo(name: "tide", remoteURL: gh("tidal", "tide"), monorepo: .pnpm(hasRealPackages: true))),
        ])
        let (scan, grouping) = await Self.discover(tree, roots: [tree.root()])
        #expect(scan.repos.map(\.name) == ["harbor-web", "tide"]) // apps/* never scanned as repos
        #expect(scan.repos[0].monorepo == nil)
        #expect(scan.repos[1].monorepo == .pnpmWorkspace)
        #expect(grouping.visibleRepos.first { $0.name == "tide" }?.isMonorepo == true)
        #expect(grouping.projects.isEmpty)
    }

    // 7.
    @Test func worktreeOfExistingRepo() async throws {
        let tree = try await FixtureTree.build([.dir("Harbor", [
            .repo(FixtureRepo(name: "harbor-oracle", remoteURL: gh("acme", "harbor-oracle"), worktrees: [
                FixtureWorktree(path: "../harbor-oracle-wt/HL-0", branch: "wt/HL-0"),
                FixtureWorktree(path: "../.worktrees/oracle-c5", branch: "c5"),
                FixtureWorktree(path: ".worktrees/inside", branch: "inside"),
            ])),
        ])])
        let (scan, grouping) = await Self.discover(tree, roots: [tree.root()])
        let oracle = tree.url("Harbor/harbor-oracle")
        let worktrees = scan.repos.filter { if case .worktree = $0.kind { true } else { false } }
        #expect(Set(worktrees.map(\.url)) == Set<URL>([tree.url("Harbor/harbor-oracle-wt/HL-0"), tree.url("Harbor/.worktrees/oracle-c5"), tree.url("Harbor/harbor-oracle/.worktrees/inside")]))
        #expect(worktrees.allSatisfy { if case .worktree(let parent, _) = $0.kind { parent == oracle } else { false } })
        #expect(worktrees.contains { $0.kind == .worktree(parent: oracle, branch: "wt/HL-0") })

        #expect(grouping.visibleRepos.count == 1)
        #expect(grouping.visibleRepos[0].primary.worktrees.count == 3)
    }

    // 8.
    @Test func submoduleRepo() async throws {
        let tree = try await FixtureTree.build([
            .repo(FixtureRepo(name: "beacon", remoteURL: gh("acme", "beacon"), submodules: [FixtureSubmodule(path: "libs/shared", sourceName: "shared")])),
        ])
        let (scan, grouping) = await Self.discover(tree, roots: [tree.root()])
        let beacon = tree.url("beacon")
        #expect(scan.repos.map(\.url) == [beacon, tree.url("beacon/libs/shared")])
        #expect(scan.repos[1].kind == .submodule(parent: beacon))
        #expect(scan.repos[1].remoteURL != nil)
        #expect(grouping.visibleRepos.map(\.name) == ["beacon"])
        #expect(grouping.visibleRepos[0].primary.submodules.map(\.name) == ["shared"])
    }

    // 9.
    @Test func orgClusteredRemotes() async throws {
        let tree = try await FixtureTree.build([.dir("Code", [
            .dir("Harbor", ["api", "console", "marketing-site", "oracle"].map { .repo(FixtureRepo(name: $0, remoteURL: gh("Acme-co", $0))) }),
            // A personal account's unrelated repos straight in the root must not become a project.
            .repo(FixtureRepo(name: "notes", remoteURL: gh("me", "notes"))),
            .repo(FixtureRepo(name: "dotfiles", remoteURL: gh("me", "dotfiles"))),
            .repo(FixtureRepo(name: "blog", remoteURL: gh("me", "blog"))),
        ])])
        let (_, grouping) = await Self.discover(tree, roots: [tree.root("Code")])
        #expect(grouping.projects.count == 1)
        let harbor = try #require(grouping.projects.first)
        #expect(harbor.name == "Harbor")
        #expect(harbor.why == "Same GitHub org: Acme-co · all in Harbor/")
        #expect(harbor.repos.count == 4)
        #expect(grouping.other.map(\.name) == ["blog", "dotfiles", "notes"])
    }

    // Rescans on real trees: a clone, a move and a deletion between two scans.
    @Test func rescanAfterChangesOnDisk() async throws {
        let tree = try await FixtureTree.build([.dir("Harbor", [
            .repo(FixtureRepo(name: "app", remoteURL: gh("acme", "app"))),
            .repo(FixtureRepo(name: "api", remoteURL: gh("acme", "api"))),
            .repo(FixtureRepo(name: "scratch")),
        ])])
        let before = await tree.scan([tree.root()])
        let fm = FileManager.default
        try fm.createDirectory(at: tree.url("Services"), withIntermediateDirectories: true)
        try fm.moveItem(at: tree.url("Harbor/api"), to: tree.url("Services/api"))
        try fm.removeItem(at: tree.url("Harbor/scratch"))
        try await tree.fixture.git(["clone", "-q", tree.url("Harbor/app").path, tree.url("Backup/app").path], in: tree.base)
        try await tree.fixture.git(["remote", "set-url", "origin", gh("acme", "app")], in: tree.url("Backup/app"))

        let after = await tree.scan([tree.root()])
        let diff = ScanDiff(from: before, to: after)
        #expect(diff.newRepos.isEmpty)
        #expect(diff.newCopies.map(\.url) == [tree.url("Backup/app")])
        #expect(diff.moved.map(\.to) == [tree.url("Services/api")])
        #expect(diff.removed.map(\.url) == [tree.url("Harbor/scratch")])
    }
}
