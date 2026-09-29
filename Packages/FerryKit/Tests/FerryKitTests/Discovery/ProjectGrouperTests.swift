import Foundation
import Testing
@testable import FerryKit

/// Project grouping as a pure function over hand-built scan results: no disk, no git.
@Suite("Project grouping rules")
struct ProjectGrouperTests {
    static let home = "/Users/tester"
    let grouper = ProjectGrouper(homeDirectory: URL(fileURLWithPath: home))

    static func repo(_ path: String, _ remote: String? = nil, kind: DiscoveredRepo.Kind = .repository, downloaded: Bool = true) -> DiscoveredRepo {
        DiscoveredRepo(url: directoryURL(path), kind: kind, isDownloaded: downloaded, remoteURL: remote)
    }

    static func scan(_ repos: [DiscoveredRepo], workspaces: [WorkspaceFile] = [], roots: [String] = ["/code"]) -> ScanResult {
        ScanResult(roots: roots.map { ScanRoot(url: directoryURL($0)) }, repos: repos, workspaceFiles: workspaces)
    }

    static func workspace(_ path: String, _ folders: [String]) -> WorkspaceFile {
        WorkspaceFile(url: URL(fileURLWithPath: path), folders: folders.map(directoryURL))
    }

    private func names(_ project: Project?) -> [String] { project?.repos.map(\.name) ?? [] }

    // MARK: Workspace files

    @Test func workspaceFileGroupsTheReposItNames() {
        let grouping = grouper.group(Self.scan([
            Self.repo("/code/Harbor/app", "git@github.com:acme/app.git"),
            Self.repo("/code/Shared/brand", "git@github.com:designco/brand.git"),
            Self.repo("/code/Other/unrelated", "git@github.com:someone/unrelated.git"),
        ], workspaces: [Self.workspace("/code/Harbor/Harbor.code-workspace", ["/code/Harbor/app", "/code/Shared/brand", "/code/Harbor/missing"])]))
        #expect(grouping.projects.count == 1)
        let project = grouping.projects[0]
        #expect(project.name == "Harbor")
        #expect(project.why == "From Harbor.code-workspace")
        #expect(project.id == ProjectID("workspace:/code/Harbor/Harbor.code-workspace"))
        #expect(names(project) == ["app", "brand"])
        #expect(grouping.other.map(\.name) == ["unrelated"])
    }

    @Test func workspaceWithOneRepoIsNoSignal() {
        let grouping = grouper.group(Self.scan([
            Self.repo("/code/Vision/beacon", "git@github.com:acme/beacon.git"),
        ], workspaces: [Self.workspace("/code/Vision/Vision.code-workspace", ["/code/Vision", "/code/Vision/beacon"])]))
        #expect(grouping.projects.isEmpty)
        #expect(grouping.other.map(\.name) == ["beacon"])
    }

    @Test func workspaceEntryPointingAtAWorktreeCountsAsItsParent() {
        let grouping = grouper.group(Self.scan([
            Self.repo("/code/a/app", "git@github.com:x/app.git"),
            Self.repo("/code/a/app-wt", "git@github.com:x/app.git", kind: .worktree(parent: directoryURL("/code/a/app"), branch: "feature")),
            Self.repo("/code/b/api", "git@github.com:y/api.git"),
        ], workspaces: [Self.workspace("/code/W.code-workspace", ["/code/a/app-wt", "/code/b/api"])]))
        #expect(names(grouping.projects.first) == ["api", "app"])
    }

    // MARK: Duplicates

    @Test func sameRemoteTwiceIsOneRepoWithTwoCopies() {
        let grouping = grouper.group(Self.scan([
            Self.repo("/code/old/harbor-app", "https://github.com/Acme/harbor-app.git"),
            Self.repo("/work/harbor-app", "git@github.com:acme/harbor-app.git"),
        ], roots: ["/code", "/work"]))
        let entries = grouping.visibleRepos
        #expect(entries.count == 1)
        #expect(entries[0].hasDuplicates)
        #expect(entries[0].duplicateSummary == "2 copies on this Mac (same remote)")
        #expect(entries[0].id == RepoID("github.com/acme/harbor-app"))
    }

    @Test func primaryCopyPrefersDownloadedThenWorkspaceThenFullerFolder() {
        let a = "git@github.com:acme/a.git", b = "git@github.com:acme/b.git"
        let fuller = grouper.group(Self.scan([
            Self.repo("/one/Harbor/a", a),
            Self.repo("/two/Harbor/a", a), Self.repo("/two/Harbor/b", b),
        ], roots: ["/one", "/two"]))
        #expect(fuller.visibleRepos.first { $0.name == "a" }?.primary.url.path == "/two/Harbor/a")

        let workspace = grouper.group(Self.scan([
            Self.repo("/one/Harbor/a", a),
            Self.repo("/two/Harbor/a", a), Self.repo("/two/Harbor/b", b),
        ], workspaces: [Self.workspace("/one/W.code-workspace", ["/one/Harbor/a"])], roots: ["/one", "/two"]))
        #expect(workspace.visibleRepos.first { $0.name == "a" }?.primary.url.path == "/one/Harbor/a")

        let downloaded = grouper.group(Self.scan([
            Self.repo("/one/Harbor/a", a),
            Self.repo("/two/Harbor/a", a, downloaded: false), Self.repo("/two/Harbor/b", b),
        ], roots: ["/one", "/two"]))
        #expect(downloaded.visibleRepos.first { $0.name == "a" }?.primary.url.path == "/one/Harbor/a")
    }

    @Test func duplicateTreesBecomeOneProject() {
        let r = { (name: String) in "git@github.com:acme/\(name).git" }
        let grouping = grouper.group(Self.scan([
            Self.repo("/one/Harbor/app", r("app")), Self.repo("/one/Harbor/admin", r("admin")),
            Self.repo("/two/Harbor/app", r("app")), Self.repo("/two/Harbor/admin", r("admin")), Self.repo("/two/Harbor/mobile", r("mobile")),
        ], roots: ["/one", "/two"]))
        #expect(grouping.projects.count == 1)
        #expect(names(grouping.projects.first) == ["admin", "app", "mobile"])
        #expect(grouping.projects[0].repos.filter(\.hasDuplicates).count == 2)
    }

    // MARK: Owner, folder, stem

    @Test func sameOwnerInAProjectFolder() {
        let grouping = grouper.group(Self.scan([
            Self.repo("/code/Harbor/api", "git@github.com:acme/api.git"),
            Self.repo("/code/Harbor/console", "git@github.com:acme/console.git"),
        ]))
        #expect(grouping.projects.first?.name == "Harbor")
        #expect(grouping.projects.first?.why == "Same GitHub org: acme · all in Harbor/")
    }

    @Test func mixedOwnersInAFolderAreFoundTogether() {
        let grouping = grouper.group(Self.scan([
            Self.repo("/code/Tide/tide", "git@github.com:acme/tide.git"),
            Self.repo("/code/Tide/tide-fork", "git@github.com:upstream/tide-fork.git"),
            Self.repo("/code/Tide/scratch"),
        ]))
        #expect(grouping.projects.first?.why == "All found together in Tide/")
        #expect(names(grouping.projects.first) == ["scratch", "tide", "tide-fork"])
    }

    @Test func ownerAloneNeverGroups() {
        // A personal account's unrelated repos, straight in the scan root.
        let grouping = grouper.group(Self.scan([
            Self.repo("/code/notes", "git@github.com:me/notes.git"),
            Self.repo("/code/dotfiles", "git@github.com:me/dotfiles.git"),
            Self.repo("/code/blog", "git@github.com:me/blog.git"),
        ]))
        #expect(grouping.projects.isEmpty)
        #expect(grouping.other.count == 3)
    }

    @Test func nameSimilarityAloneNeverGroups() {
        let grouping = grouper.group(Self.scan([
            Self.repo("/code/harbor-app"),
            Self.repo("/code/harbor-admin", "git@github.com:someone/harbor-admin.git"),
            Self.repo("/code/harbor-web", "git@github.com:other/harbor-web.git"),
        ]))
        #expect(grouping.projects.isEmpty)
    }

    @Test func sameOwnerAndStemGroupsAcrossFolders() {
        let grouping = grouper.group(Self.scan([
            Self.repo("/code/harbor-app", "git@github.com:acme/harbor-app.git"),
            Self.repo("/code/misc/harbor-tools", "git@github.com:acme/harbor-tools.git"),
            Self.repo("/code/beacon", "git@github.com:acme/beacon.git"),
        ]))
        #expect(grouping.projects.count == 1)
        #expect(grouping.projects[0].name == "harbor")
        #expect(grouping.projects[0].why == "Same GitHub org: acme · names start with “harbor”")
        #expect(grouping.other.map(\.name) == ["beacon"])
    }

    @Test func containerFoldersDoNotGroup() {
        let home = Self.home
        let grouping = grouper.group(Self.scan([
            // Direct child of home.
            Self.repo("\(home)/Developer/a", "git@github.com:me/a.git"), Self.repo("\(home)/Developer/b", "git@github.com:me/b.git"),
            // Conventional clone shelf.
            Self.repo("\(home)/Documents/GitHub/c", "git@github.com:me/c.git"), Self.repo("\(home)/Documents/GitHub/d", "git@github.com:me/d.git"),
        ], roots: [home]))
        #expect(grouping.projects.isEmpty)
    }

    @Test func largeFolderIsAShelfUnlessNamesShareAStem() {
        let diverse = ["api", "web", "infra", "docs", "mobile", "admin", "billing", "search", "auth"]
        let shelf = grouper.group(Self.scan(diverse.map { Self.repo("/code/Stuff/\($0)", "git@github.com:me/\($0).git") }))
        #expect(shelf.projects.isEmpty)

        let product = grouper.group(Self.scan(diverse.map { Self.repo("/code/Harbor/Harbor\($0.capitalized)", "git@github.com:acme/Harbor\($0.capitalized).git") }))
        #expect(product.projects.count == 1)
        #expect(product.projects[0].repos.count == 9)
    }

    @Test func ghqLayoutIsRecognised() {
        let grouping = grouper.group(Self.scan([
            Self.repo("/ghq/github.com/acme/api", "https://github.com/acme/api"),
            Self.repo("/ghq/github.com/acme/web", "https://github.com/acme/web"),
        ], roots: ["/ghq"]))
        #expect(grouping.projects.first?.name == "acme")
        #expect(grouping.projects.first?.why == "Matches your github.com/acme/… folder layout")
    }

    @Test func overlappingSignalsMergeStrongestFirst() {
        let grouping = grouper.group(Self.scan([
            Self.repo("/code/Harbor/app", "git@github.com:acme/app.git"),
            Self.repo("/code/Harbor/admin", "git@github.com:acme/admin.git"),
            Self.repo("/code/Harbor/docs", "git@github.com:acme/docs.git"),
        ], workspaces: [Self.workspace("/code/Harbor/Main.code-workspace", ["/code/Harbor/app", "/code/Harbor/admin"])]))
        #expect(grouping.projects.count == 1)
        let project = grouping.projects[0]
        #expect(project.name == "Main")
        #expect(project.reasons.first == .workspaceFile(fileName: "Main.code-workspace"))
        #expect(project.aliases.contains(ProjectID("folder:/code/Harbor")))
        #expect(project.repos.count == 3)
    }

    // MARK: Worktrees, submodules, not-related

    @Test func worktreesAndSubmodulesAttachToTheirParent() {
        let app = directoryURL("/code/Harbor/app")
        let grouping = grouper.group(Self.scan([
            Self.repo("/code/Harbor/app", "git@github.com:acme/app.git"),
            Self.repo("/code/Harbor/app-wt/HL-0", "git@github.com:acme/app.git", kind: .worktree(parent: app, branch: "wt/HL-0")),
            Self.repo("/code/Harbor/app/libs/shared", "/srv/shared", kind: .submodule(parent: app)),
            Self.repo("/code/Harbor/app/libs/shared/deep", "/srv/deep", kind: .submodule(parent: directoryURL("/code/Harbor/app/libs/shared"))),
            // Parent not found (a bare clone's worktree): shown as a repo so it isn't lost.
            Self.repo("/code/Harbor/orphan", "git@github.com:acme/orphan.git", kind: .worktree(parent: directoryURL("/srv/orphan.git"), branch: "main")),
        ]))
        let entries = grouping.visibleRepos
        #expect(entries.map(\.name).sorted() == ["app", "orphan"])
        let copy = entries.first { $0.name == "app" }!.primary
        #expect(copy.worktrees.map(\.name) == ["HL-0"])
        #expect(copy.submodules.map(\.name).sorted() == ["deep", "shared"])
    }

    @Test func notRelatedPairsAreKeptApart() {
        let scan = Self.scan([
            Self.repo("/code/Harbor/app", "git@github.com:acme/app.git"),
            Self.repo("/code/Harbor/admin", "git@github.com:acme/admin.git"),
            Self.repo("/code/Harbor/lab", "git@github.com:acme/lab.git"),
        ])
        let grouping = grouper.group(scan, keepingApart: [RepoPair(RepoID("github.com/acme/lab"), RepoID("github.com/acme/app"))])
        #expect(grouping.projects.count == 1)
        #expect(!names(grouping.projects.first).contains("lab") || !names(grouping.projects.first).contains("app"))
        #expect(grouping.visibleRepos.count == 3)
    }

    @Test func groupingIsDeterministic() {
        let scan = Self.scan((0..<6).map { Self.repo("/code/P\($0 % 2)/r\($0)", "git@github.com:o\($0 % 2)/r\($0).git") })
        #expect(grouper.group(scan) == grouper.group(scan))
    }
}
