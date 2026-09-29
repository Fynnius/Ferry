import Foundation

/// A folder the user chose to scan, with how deep to look below it (VS Code's too-shallow
/// fixed depth is a recurring complaint, so it's per root).
public struct ScanRoot: Hashable, Sendable, Codable {
    public static let defaultMaxDepth = 6

    public var url: URL
    /// Folder levels below `url` that are still searched; 0 checks only `url` itself
    /// (how a manually added repo is scanned).
    public var maxDepth: Int

    public init(url: URL, maxDepth: Int = ScanRoot.defaultMaxDepth) {
        self.url = directoryURL(url.path)
        self.maxDepth = max(0, maxDepth)
    }
}

/// A working tree found on disk. Worktrees and submodules carry their parent so the
/// grouping can attach them to it instead of listing them as repos of their own.
public struct DiscoveredRepo: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case repository
        /// A linked worktree (`.git` file → `<parent>/.git/worktrees/<name>`).
        case worktree(parent: URL, branch: String?)
        /// A submodule checked out inside `parent`.
        case submodule(parent: URL)
    }

    public var url: URL
    public var kind: Kind
    /// False when the repo's git data is a cloud placeholder (iCloud "Optimize Mac Storage",
    /// File Provider). Such repos are listed but never opened with git: git would silently
    /// download them.
    public var isDownloaded: Bool
    /// Set when the repo is a validated monorepo (one repo, many packages — never split).
    public var monorepo: MonorepoKind?
    /// Fetch URL of `origin` (or the first remote), as git reports it — `insteadOf` applied.
    public var remoteURL: String?

    public init(url: URL, kind: Kind = .repository, isDownloaded: Bool = true, monorepo: MonorepoKind? = nil, remoteURL: String? = nil) {
        self.url = url
        self.kind = kind
        self.isDownloaded = isDownloaded
        self.monorepo = monorepo
        self.remoteURL = remoteURL
    }

    public var name: String { url.lastPathComponent }
    public var path: String { url.path }
    public var remote: RemoteIdentity? { remoteURL.flatMap(RemoteIdentity.init(remoteURL:)) }
}

/// Which manifest proved a repo is a monorepo.
public enum MonorepoKind: String, Hashable, Sendable, Codable {
    /// `pnpm-workspace.yaml` with `packages:` globs that match real folders.
    case pnpmWorkspace
    /// `package.json` `workspaces` globs (npm, Yarn, Bun) that match real folders.
    case packageJSONWorkspaces
}

/// A `.code-workspace` file with its folder entries resolved to absolute paths. Entries
/// may point at folders that are gone or aren't repos; the grouper validates them.
public struct WorkspaceFile: Hashable, Sendable, Codable {
    public var url: URL
    public var folders: [URL]

    public init(url: URL, folders: [URL]) {
        self.url = url
        self.folders = folders
    }

    /// "Harbor" for `Harbor.code-workspace`.
    public var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Everything one scan found. Sorted by path so equal trees give equal results.
public struct ScanResult: Hashable, Sendable, Codable {
    public var roots: [ScanRoot]
    public var repos: [DiscoveredRepo]
    /// Bare repos (no working tree): reported, but nothing to commit in, so not listed as repos.
    public var bareRepositories: [URL]
    public var workspaceFiles: [WorkspaceFile]
    /// Folders not searched because they're cloud placeholders (reading would download them).
    public var notDownloadedFolders: [URL]
    /// Roots that don't exist or couldn't be read (moved, unplugged, permission revoked).
    public var unreadableRoots: [URL]
    /// True when the scan was stopped before it finished; the lists are partial.
    public var wasCancelled: Bool

    public init(
        roots: [ScanRoot] = [],
        repos: [DiscoveredRepo] = [],
        bareRepositories: [URL] = [],
        workspaceFiles: [WorkspaceFile] = [],
        notDownloadedFolders: [URL] = [],
        unreadableRoots: [URL] = [],
        wasCancelled: Bool = false
    ) {
        self.roots = roots
        self.repos = repos
        self.bareRepositories = bareRepositories
        self.workspaceFiles = workspaceFiles
        self.notDownloadedFolders = notDownloadedFolders
        self.unreadableRoots = unreadableRoots
        self.wasCancelled = wasCancelled
    }
}

/// What a running scan reports, in order: many `progress`/`found`, then one `finished`.
public enum ScanEvent: Sendable {
    /// Throttled (at most ~20 per second) so a huge tree can't flood the UI.
    case progress(ScanProgress)
    /// A repo, worktree or submodule, with its remote already read.
    case found(DiscoveredRepo)
    case foundBareRepository(URL)
    case finished(ScanResult)
}

public struct ScanProgress: Hashable, Sendable {
    public var currentFolder: URL
    public var foldersVisited: Int
    public var reposFound: Int
}
