#if DEBUG
import Foundation
import FerryKit

/// A believable, non-personal fleet for mockups, previews and screenshots.
enum SampleData {
    static func projects() -> [ProjectItem] {
        func repo(_ name: String, _ dir: String, _ status: RepoStatus, message: String = "", protected: Bool = false) -> RepoItem {
            let item = RepoItem(id: "\(dir)/\(name)", name: name, path: URL(fileURLWithPath: "/Users/sam/Developer/\(dir)/\(name)"), status: status)
            item.message = message
            item.isProtectedBranchOverride = protected
            return item
        }
        func f(_ path: String, _ kind: FileChange.Kind, _ area: FileChange.Area) -> FileChange {
            FileChange(path: path, kind: kind, area: area)
        }

        let web = repo("harbor-web", "Harbor", RepoStatus(
            branch: BranchState(head: "feature/checkout", oid: "a1b2c3d", upstream: "origin/feature/checkout", ahead: 1),
            unstaged: [
                f("src/routes/checkout/+page.svelte", .modified, .unstaged),
                f("src/lib/cart/total.ts", .modified, .unstaged),
                f("src/lib/cart/legacy-total.ts", .deleted, .unstaged),
            ],
            untracked: [f("src/lib/cart/total.test.ts", .untracked, .untracked)]
        ), message: "Move cart totals into one tested helper")

        let api = repo("harbor-api", "Harbor", RepoStatus(
            branch: BranchState(head: "main", oid: "b2c3d4e", upstream: "origin/main"),
            staged: [f("migrations/0042_orders_index.sql", .added, .staged), f("app/orders/service.py", .modified, .staged)],
            unstaged: [f("README.md", .modified, .unstaged)]
        ), protected: true)

        let docs = repo("harbor-docs", "Harbor", RepoStatus(
            branch: BranchState(head: "main", oid: "c3d4e5f", upstream: "origin/main", ahead: 0, behind: 3)
        ), protected: true)

        let marketing = repo("harbor-site", "Harbor", RepoStatus(
            branch: BranchState(head: "main", oid: "d4e5f6a", upstream: "origin/main")
        ), protected: true)

        let ios = repo("harbor-ios", "Harbor", RepoStatus(
            branch: BranchState(head: "release/2.4", oid: "e5f6a7b", upstream: nil)
        ))

        let atlas = repo("atlas", "Atlas", RepoStatus(
            branch: BranchState(head: "main", oid: "f6a7b8c", upstream: "origin/main", ahead: 2)
        ), protected: true)

        let atlasCLI = repo("atlas-cli", "Atlas", RepoStatus(
            branch: BranchState(head: "main", oid: "a7b8c9d", upstream: "origin/main"),
            stashCount: 1
        ), protected: true)

        let dotfiles = repo("dotfiles", "Personal", RepoStatus(
            branch: BranchState(head: "main", oid: "b8c9d0e", upstream: "origin/main"),
            unstaged: [f("zsh/.zshrc", .modified, .unstaged)]
        ), protected: true)

        let blog = repo("blog", "Personal", RepoStatus(
            branch: BranchState(head: "main", oid: "c9d0e1f", upstream: "origin/main")
        ), protected: true)

        let sandbox = repo("swift-sandbox", "Personal", RepoStatus(
            branch: BranchState(head: "main", oid: "d0e1f2a"), hasRemote: false
        ))

        return [
            ProjectItem(id: "harbor", name: "Harbor", repos: [web, api, docs, ios, marketing], reason: "From Harbor.code-workspace"),
            ProjectItem(id: "atlas", name: "Atlas", repos: [atlas, atlasCLI], reason: "Same GitHub org: atlas-labs"),
            ProjectItem(id: "personal", name: "Personal", repos: [dotfiles, blog, sandbox], reason: "All found together in Developer/"),
        ]
    }
}
#endif
