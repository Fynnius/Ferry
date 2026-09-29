import AppKit
import SwiftUI
import Testing
@testable import Ferry
import FerryKit

/// Offscreen design checks: renders stack pieces to PNGs without a window or the screen.
/// Off by default; run with `TEST_RUNNER_FERRY_SNAPSHOTS=<dir>` in the environment of
/// `xcodebuild test` and look at the files.
@MainActor
@Suite("Snapshots", .enabled(if: ProcessInfo.processInfo.environment["FERRY_SNAPSHOTS"] != nil))
struct SnapshotTests {
    private let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FERRY_SNAPSHOTS"] ?? NSTemporaryDirectory())

    @Test func bigChangeList() throws {
        let big = SnapshotFleet.bigRepo()
        for dark in [false, true] {
            for width in [420.0, 900.0] {
                try render(RepoSection(repo: big), width: width, height: 1400, dark: dark, name: "big-\(Int(width))-\(dark ? "dark" : "light")")
            }
        }
        // Staged, then edited again: the same paths in both groups.
        let again = SnapshotFleet.bigRepo(staged: 12, unstaged: 20, editedAgain: 12)
        try render(RepoSection(repo: again), width: 600, height: 1100, dark: false, name: "edited-again")
        let many = SnapshotFleet.bigRepo(staged: 0, unstaged: 144, editedAgain: 0)
        try render(RepoSection(repo: many), width: 600, height: 700, dark: false, name: "144-changes")
        let modules = RepoItem(id: "m", name: "ChartScope-Screener", path: URL(fileURLWithPath: "/tmp/m"), status: RepoStatus(
            branch: BranchState(head: "main", oid: "abc", upstream: "origin/main"),
            unstaged: [FileChange(path: "package.json", kind: .modified, area: .unstaged)],
            untracked: (0..<13_276).map { FileChange(path: "node_modules/pkg\($0 % 400)/f\($0).js", kind: .untracked, area: .untracked) }
        ))
        modules.isProtectedBranchOverride = false
        try render(RepoSection(repo: modules), width: 420, height: 500, dark: true, name: "13277-changes-dark")
    }

    @Test func stack() throws {
        let app = SnapshotFleet.app()
        for selection in [SidebarItem.attention, .all] {
            app.selection = selection
            for (width, dark) in [(420.0, false), (760.0, false), (1300.0, false), (1300.0, true)] {
                let name = "stack-\(selection == .attention ? "attention" : "all")-\(Int(width))-\(dark ? "dark" : "light")"
                try render(RepoStackView().environment(app), width: width, height: 2200, dark: dark, name: name)
            }
        }
        // Nothing needs you, but there are updates and dormant work.
        app.selection = .attention
        app.projects = app.projects.map { project in
            ProjectItem(id: project.id, name: project.name, repos: project.repos.filter { !$0.needsAttention && $0.worktreeOf == nil })
        }
        try render(RepoStackView().environment(app), width: 700, height: 700, dark: false, name: "stack-all-clear")
    }

    private func render(_ view: some View, width: CGFloat, height: CGFloat, dark: Bool, name: String) throws {
        let host = NSHostingView(rootView: view
            .padding(16)
            .frame(width: width, height: height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

/// Sample repos shaped like the user's real fleet.
@MainActor
enum SnapshotFleet {
    /// SampleData plus worktrees, a duplicate clone, updates, dormant work and a big repo.
    static func app() -> AppModel {
        let app = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "ferry-snapshots-\(UUID())")!), dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-snapshots-\(UUID())"))
        var projects = SampleData.projects()
        func repo(_ name: String, _ status: RepoStatus) -> RepoItem {
            let item = RepoItem(id: "/p/\(name)", name: name, path: URL(fileURLWithPath: "/Users/sam/Developer/Tide/\(name)"), status: status)
            item.isProtectedBranchOverride = false
            return item
        }
        let mobile = repo("TideMobile", RepoStatus(branch: BranchState(head: "main", oid: "a", upstream: "origin/main")))
        mobile.copies = [mobile.path, URL(fileURLWithPath: "/Users/sam/Projects/TideMobile")]
        mobile.note = "2 copies on this Mac (same remote)"
        let worktrees = ["feat/home-shell", "feat/lists", "feat/auth", "fix/crash-on-launch", "chore/deps", "feat/widgets"].enumerated().map { index, branch in
            let item = repo("wt_3f2a9c1b-89e-\(index + 1)", RepoStatus(
                branch: BranchState(head: branch, oid: "b", upstream: "origin/\(branch)"),
                unstaged: index == 0 ? [FileChange(path: "app/(tabs)/home.tsx", kind: .modified, area: .unstaged), FileChange(path: "app/(tabs)/_layout.tsx", kind: .modified, area: .unstaged)] : []
            ))
            item.worktreeOf = mobile.id
            item.note = "Worktree of TideMobile"
            item.lastEditedAt = .now.addingTimeInterval(-600)
            return item
        }
        let server = repo("TideServer", RepoStatus(branch: BranchState(head: "main", oid: "c", upstream: "origin/main", behind: 34)))
        let oracle = repo("TideOracle", RepoStatus(branch: BranchState(head: "main", oid: "d", upstream: "origin/main"), unstaged: [FileChange(path: "notes.md", kind: .modified, area: .unstaged)]))
        oracle.lastEditedAt = .now.addingTimeInterval(-RepoItem.dormantAfter - 40 * 86_400)
        projects.append(ProjectItem(id: "tide", name: "Tide", repos: [mobile] + worktrees + [server, oracle]))
        let big = bigRepo(staged: 1598, unstaged: 144, editedAgain: 3)
        big.lastEditedAt = .now.addingTimeInterval(-7200)
        projects.append(ProjectItem(id: "cc", name: "Storefront", repos: [big]))
        app.projects = projects
        app.repos = Dictionary(uniqueKeysWithValues: app.allRepos.map { ($0.id, $0) })
        for repo in app.allRepos {
            repo.app = app
            if repo.status?.hasChanges == true, repo.lastEditedAt == nil { repo.lastEditedAt = .now.addingTimeInterval(-3 * 3600) }
        }
        // A folded card keeps its typed message: the "Draft" tag.
        if let web = app.allRepos.first(where: { $0.name == "harbor-web" }) { app.userFolded[web.id] = true }
        return app
    }

    static func bigRepo(staged: Int = 1598, unstaged: Int = 144, editedAgain: Int = 3) -> RepoItem {
        let stagedFiles = (0..<staged).map { i in
            FileChange(path: "storefront-landing/\(["src/components", "src/pages", "public/img", "src/lib"][i % 4])/file\(i).tsx", kind: .added, area: .staged)
        }
        let unstagedFiles = (0..<unstaged).map { i in
            FileChange(path: "app/\(["routes", "models", "views"][i % 3])/item\(i).swift", kind: .modified, area: .unstaged)
        }
        // A few files staged, then edited again: they show in both groups.
        let again = stagedFiles.prefix(editedAgain).map { FileChange(path: $0.path, kind: .modified, area: .unstaged) }
        let item = RepoItem(id: "big", name: "Storefront", path: URL(fileURLWithPath: "/tmp/Storefront"), status: RepoStatus(
            branch: BranchState(head: "main", oid: "abc", upstream: "origin/main"),
            staged: stagedFiles,
            unstaged: again + unstagedFiles
        ))
        item.isProtectedBranchOverride = false
        return item
    }
}
