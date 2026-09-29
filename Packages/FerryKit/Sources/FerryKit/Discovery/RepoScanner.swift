import Foundation

/// Finds repos below the folders the user chose. Walks directories itself —
/// descent is pruned, not filtered — stops at each repo root, and reads remotes with
/// git as repos turn up so results stream in already identified.
///
/// Cloud safety: every item is checked from metadata before it's opened.
/// Placeholder folders aren't entered; a repo whose git data is a placeholder is
/// reported with `isDownloaded == false` and git never runs in it.
public struct RepoScanner: Sendable {
    public struct Options: Sendable {
        /// Folder names never entered: dependency trees, build output, caches.
        public var skippedFolderNames: Set<String>
        /// Package-like folders (`Foo.app`) that never hold repos but can be huge.
        public var skippedFolderExtensions: Set<String>
        /// `Library` is skipped only directly under this folder (`~/Library`: caches and
        /// app data, huge and never where people keep code). Nil disables the rule.
        public var homeDirectory: URL?

        public init(
            skippedFolderNames: Set<String> = Options.defaultSkippedFolderNames,
            skippedFolderExtensions: Set<String> = Options.defaultSkippedFolderExtensions,
            homeDirectory: URL? = FileManager.default.homeDirectoryForCurrentUser
        ) {
            self.skippedFolderNames = skippedFolderNames
            self.skippedFolderExtensions = skippedFolderExtensions
            self.homeDirectory = homeDirectory
        }

        public static let defaultSkippedFolderNames: Set<String> = [
            ".git", "node_modules", ".build", "DerivedData", "Pods", "vendor", "dist", "build", "target",
            ".venv", "venv", "__pycache__", ".Trash",
            // Hidden tool caches and stores (anything ending in "cache" is skipped too).
            ".cache", ".npm", ".pnpm-store", ".yarn", ".gradle", ".m2", ".cargo", ".rustup", ".nvm",
            ".pyenv", ".rbenv", ".gem", ".cocoapods", ".swiftpm", ".tox", ".next", ".nuxt", ".turbo",
            ".expo", ".terraform", ".docker", ".vscode", ".cursor",
            // Volume bookkeeping.
            ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
        ]

        public static let defaultSkippedFolderExtensions: Set<String> = [
            "app", "photoslibrary", "xcodeproj", "xcworkspace", "xcarchive", "framework",
        ]
    }

    public let runner: GitRunner?
    public let options: Options
    public let fileSystem: any FileSystemReading

    /// - Parameter runner: reads each repo's remote; nil skips that (no git calls at all).
    public init(runner: GitRunner?, options: Options = Options(), fileSystem: any FileSystemReading = LocalFileSystem()) {
        self.runner = runner
        self.options = options
        self.fileSystem = fileSystem
    }

    /// Scans in the background and streams what it finds. Dropping the stream (or
    /// cancelling the task iterating it) stops the scan at the next folder.
    public func events(for roots: [ScanRoot]) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                _ = await scan(roots) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Scans and returns the result; `onEvent` sees the same events as `events(for:)`.
    /// Cancelling the calling task stops the walk and returns a partial result.
    public func scan(_ roots: [ScanRoot], onEvent: (@Sendable (ScanEvent) -> Void)? = nil) async -> ScanResult {
        let emit: @Sendable (ScanEvent) -> Void = onEvent ?? { _ in }
        var walk = Walk(scanner: self, emit: emit)
        var repos: [DiscoveredRepo] = []

        await withTaskGroup(of: DiscoveredRepo.self) { group in
            func inspect(_ found: [DiscoveredRepo]) {
                for repo in found {
                    group.addTask { [runner] in
                        var repo = repo
                        if let runner, repo.isDownloaded {
                            repo.remoteURL = await Self.readRemote(of: repo.url, runner: runner)
                        }
                        emit(.found(repo))
                        return repo
                    }
                }
            }
            for root in roots {
                guard walk.begin(root) else { continue }
                while !Task.isCancelled, walk.step() {
                    inspect(walk.takeFound())
                    // The walk is synchronous file I/O; let other work run on this thread now and then.
                    if walk.foldersVisited % 64 == 0 { await Task.yield() }
                }
                inspect(walk.takeFound())
                if Task.isCancelled { break }
            }
            for await repo in group { repos.append(repo) }
        }

        let result = ScanResult(
            // Real paths, like every repo path, so the grouper can compare them.
            roots: roots.map { ScanRoot(url: canonicalURL($0.url) ?? $0.url, maxDepth: $0.maxDepth) },
            repos: repos.sorted { $0.path < $1.path },
            bareRepositories: walk.bare.sorted { $0.path < $1.path },
            workspaceFiles: walk.workspaces.sorted { $0.url.path < $1.url.path },
            notDownloadedFolders: walk.notDownloaded.sorted { $0.path < $1.path },
            unreadableRoots: walk.unreadableRoots,
            wasCancelled: Task.isCancelled
        )
        emit(.finished(result))
        return result
    }

    /// `origin`'s fetch URL, else the first remote's. `remote -v` reports URLs after
    /// `insteadOf` rewriting, which is what identifies the repo.
    static func readRemote(of repo: URL, runner: GitRunner) async -> String? {
        guard let output = try? await runner.runAllowingFailure(["remote", "-v"], in: repo), output.exitCode == 0 else { return nil }
        var fetchURLs: [(name: String, url: String)] = []
        for line in output.text.split(separator: "\n") where line.hasSuffix(" (fetch)") {
            let fields = line.dropLast(" (fetch)".count).split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            fetchURLs.append((String(fields[0]), String(fields[1])))
        }
        return (fetchURLs.first { $0.name == "origin" } ?? fetchURLs.first)?.url
    }
}

// MARK: - Walk

/// Mutable state of one scan; lives only inside `scan`.
private struct Walk {
    let scanner: RepoScanner
    let emit: @Sendable (ScanEvent) -> Void

    var seenRepoPaths: Set<String> = []
    var bare: [URL] = []
    var workspaces: [WorkspaceFile] = []
    var seenWorkspaces: Set<String> = []
    var notDownloaded: [URL] = []
    var unreadableRoots: [URL] = []
    var foldersVisited = 0
    private var found: [DiscoveredRepo] = []
    private var stack: [(url: URL, depth: Int)] = []
    private var maxDepth = 0
    private var currentRoot = URL(fileURLWithPath: "/")
    private var lastProgress: ContinuousClock.Instant?

    private var fs: any FileSystemReading { scanner.fileSystem }

    init(scanner: RepoScanner, emit: @escaping @Sendable (ScanEvent) -> Void) {
        self.scanner = scanner
        self.emit = emit
    }

    /// Starts on a root; false when it doesn't exist.
    mutating func begin(_ root: ScanRoot) -> Bool {
        guard let start = canonicalURL(root.url) else {
            unreadableRoots.append(root.url)
            return false
        }
        stack = [(start, 0)]
        maxDepth = root.maxDepth
        currentRoot = root.url
        return true
    }

    /// Repos recorded since the last call, for the caller to inspect.
    mutating func takeFound() -> [DiscoveredRepo] {
        defer { found.removeAll() }
        return found
    }

    /// Visits one folder. False when the current root is done.
    mutating func step() -> Bool {
        guard let (dir, depth) = stack.popLast() else { return false }
        // Permission denied (other apps' containers, TCC) or vanished: skip silently,
        // but a root the user chose that can't be read is worth telling them about.
        guard let entries = try? fs.entries(of: dir) else {
            if depth == 0 { unreadableRoots.append(currentRoot) }
            return true
        }
        foldersVisited += 1
        reportProgress(dir)

        collectWorkspaceFiles(in: dir, entries: entries)

        if let marker = entries.first(where: { $0.name == ".git" }) {
            handleRepo(at: dir, marker: marker, entries: entries)
            return true // Never look for more repos inside a repo's own tree.
        }
        if Self.isBareRepository(entries) {
            bare.append(dir)
            emit(.foundBareRepository(dir))
            return true
        }
        guard depth < maxDepth else { return true }
        for entry in entries.reversed() where entry.isDirectory && !entry.isSymbolicLink {
            guard !shouldSkip(entry.name, in: dir) else { continue }
            let child = dir.appendingPathComponent(entry.name, isDirectory: true)
            if entry.isPlaceholder {
                notDownloaded.append(child)
            } else {
                stack.append((child, depth + 1))
            }
        }
        return true
    }

    private mutating func reportProgress(_ dir: URL) {
        let now = ContinuousClock.now
        if let last = lastProgress, now - last < .milliseconds(50) { return }
        lastProgress = now
        emit(.progress(ScanProgress(currentFolder: dir, foldersVisited: foldersVisited, reposFound: seenRepoPaths.count)))
    }

    private func shouldSkip(_ name: String, in parent: URL) -> Bool {
        let options = scanner.options
        if options.skippedFolderNames.contains(name) { return true }
        if name.hasPrefix("."), name.lowercased().hasSuffix("cache") { return true }
        if name == "Library", let home = options.homeDirectory,
           parent.path == (canonicalURL(home) ?? home).path { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && options.skippedFolderExtensions.contains(ext)
    }

    static func isBareRepository(_ entries: [DirectoryEntry]) -> Bool {
        entries.contains { $0.name == "HEAD" && !$0.isDirectory }
            && entries.contains { $0.name == "objects" && $0.isDirectory }
            && entries.contains { $0.name == "refs" && $0.isDirectory }
    }

    // MARK: Repos

    private mutating func handleRepo(at dir: URL, marker: DirectoryEntry, entries: [DirectoryEntry]) {
        guard let repo = classify(dir, marker: marker) else { return }
        guard record(repo) else { return }
        guard repo.isDownloaded, repo.kind == .repository else { return }
        attachSubmodules(of: dir, entries: entries)
        attachWorktrees(of: dir)
    }

    /// Records a repo once (roots can overlap; worktrees are reachable two ways).
    private mutating func record(_ repo: DiscoveredRepo) -> Bool {
        guard seenRepoPaths.insert(repo.path).inserted else { return false }
        found.append(repo)
        return true
    }

    /// What kind of working tree `dir` is, from its `.git` directory or file. Nil for a
    /// `.git` file whose target is gone (a worktree of a deleted repo): skipped silently.
    private func classify(_ dir: URL, marker: DirectoryEntry) -> DiscoveredRepo? {
        let gitURL = dir.appendingPathComponent(".git", isDirectory: marker.isDirectory)
        if marker.isPlaceholder || fs.isPlaceholder(gitURL) {
            return DiscoveredRepo(url: dir, isDownloaded: false)
        }
        if marker.isDirectory {
            let essentials = ["HEAD", "config"].map { gitURL.appendingPathComponent($0) }
            if essentials.contains(where: { fs.isPlaceholder($0) }) {
                return DiscoveredRepo(url: dir, isDownloaded: false)
            }
            return DiscoveredRepo(url: dir, monorepo: monorepoKind(of: dir), lastActivity: lastActivity(gitDir: gitURL))
        }

        // A `.git` file: `gitdir: <path>` for worktrees, submodules and --separate-git-dir.
        guard let gitDir = readGitDirPointer(gitURL, relativeTo: dir) else { return nil }
        let commonDirFile = gitDir.appendingPathComponent("commondir")
        if let common = readText(commonDirFile)?.trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
            let commonURL = common.hasPrefix("/") ? URL(fileURLWithPath: common) : gitDir.appendingPathComponent(common)
            guard let commonDir = canonicalURL(commonURL) else { return nil }
            // `<main>/.git` for a normal repo; the bare repo itself when worktrees hang off a bare clone.
            let parent = commonDir.lastPathComponent == ".git" ? commonDir.deletingLastPathComponent() : commonDir
            return DiscoveredRepo(url: dir, kind: .worktree(parent: directoryURL(parent.path), branch: branch(inGitDir: gitDir)), lastActivity: lastActivity(gitDir: gitDir))
        }
        if let range = gitDir.path.range(of: "/.git/modules/") {
            return DiscoveredRepo(url: dir, kind: .submodule(parent: directoryURL(String(gitDir.path[..<range.lowerBound]))), lastActivity: lastActivity(gitDir: gitDir))
        }
        return DiscoveredRepo(url: dir, monorepo: monorepoKind(of: dir), lastActivity: lastActivity(gitDir: gitDir))
    }

    /// Newest of the git dir's `index` and `logs/HEAD` (see `DiscoveredRepo.lastActivity`).
    /// Stats only; `logs` is skipped when it's a placeholder folder, since looking up a
    /// name inside one would download it.
    private func lastActivity(gitDir: URL) -> Date? {
        let logs = gitDir.appendingPathComponent("logs", isDirectory: true)
        var candidates = [gitDir.appendingPathComponent("index")]
        if !fs.isPlaceholder(logs) { candidates.append(logs.appendingPathComponent("HEAD")) }
        return candidates.compactMap { fs.modificationDate(of: $0) }.max()
    }

    /// Submodules are known from `.gitmodules`, so there's no need to walk the parent's tree.
    private mutating func attachSubmodules(of dir: URL, entries: [DirectoryEntry]) {
        guard entries.contains(where: { $0.name == ".gitmodules" && !$0.isDirectory }),
              let text = readText(dir.appendingPathComponent(".gitmodules")) else { return }
        for path in ManifestParsing.submodulePaths(text) {
            let subdir = directoryURL(dir.appendingPathComponent(path).path)
            guard let subEntries = try? fs.entries(of: subdir),
                  let marker = subEntries.first(where: { $0.name == ".git" }),
                  var sub = classify(subdir, marker: marker) else { continue } // Not checked out.
            sub.kind = .submodule(parent: dir)
            sub.monorepo = nil
            guard record(sub), sub.isDownloaded else { continue }
            attachSubmodules(of: subdir, entries: subEntries)
        }
    }

    /// The main repo lists its linked worktrees in `.git/worktrees/<name>/gitdir`; this
    /// also finds worktrees kept inside the repo (`.worktrees/…`) or outside the roots.
    private mutating func attachWorktrees(of dir: URL) {
        let admin = dir.appendingPathComponent(".git/worktrees", isDirectory: true)
        guard let entries = try? fs.entries(of: admin) else { return }
        for entry in entries where entry.isDirectory && !entry.isPlaceholder {
            let gitDir = admin.appendingPathComponent(entry.name, isDirectory: true)
            guard let pointer = readText(gitDir.appendingPathComponent("gitdir"))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let dotGit = canonicalURL(URL(fileURLWithPath: pointer)) else { continue } // Pruned worktree.
            let root = directoryURL(dotGit.deletingLastPathComponent().path)
            let downloaded = !fs.isPlaceholder(URL(fileURLWithPath: dotGit.path))
            _ = record(DiscoveredRepo(
                url: root, kind: .worktree(parent: dir, branch: branch(inGitDir: gitDir)),
                isDownloaded: downloaded, lastActivity: downloaded ? lastActivity(gitDir: gitDir) : nil
            ))
        }
    }

    private func readGitDirPointer(_ file: URL, relativeTo dir: URL) -> URL? {
        guard let text = readText(file),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
        return canonicalURL(url)
    }

    private func branch(inGitDir gitDir: URL) -> String? {
        guard let head = readText(gitDir.appendingPathComponent("HEAD"))?.trimmingCharacters(in: .whitespacesAndNewlines),
              head.hasPrefix("ref: refs/heads/") else { return nil } // Detached.
        return String(head.dropFirst("ref: refs/heads/".count))
    }

    // MARK: Manifests

    private func monorepoKind(of dir: URL) -> MonorepoKind? {
        if let yaml = readText(dir.appendingPathComponent("pnpm-workspace.yaml")),
           ManifestParsing.anyGlobResolves(ManifestParsing.pnpmPackageGlobs(yaml), in: dir, fileSystem: fs) {
            return .pnpmWorkspace
        }
        if let data = readData(dir.appendingPathComponent("package.json")),
           ManifestParsing.anyGlobResolves(ManifestParsing.packageJSONWorkspaceGlobs(data), in: dir, fileSystem: fs) {
            return .packageJSONWorkspaces
        }
        return nil
    }

    private mutating func collectWorkspaceFiles(in dir: URL, entries: [DirectoryEntry]) {
        for entry in entries where !entry.isDirectory && entry.name.hasSuffix(".code-workspace") {
            let url = dir.appendingPathComponent(entry.name, isDirectory: false)
            guard !entry.isPlaceholder, seenWorkspaces.insert(url.path).inserted,
                  let data = readData(url),
                  let folders = ManifestParsing.workspaceFolders(data, relativeTo: dir) else { continue }
            // Real paths where the folder exists; dangling entries stay as written for the grouper to drop.
            workspaces.append(WorkspaceFile(url: url, folders: folders.map { canonicalURL($0) ?? $0 }))
        }
    }

    // MARK: Reading

    /// Reads a small file only if it exists and isn't a cloud placeholder.
    private func readData(_ url: URL) -> Data? {
        guard !fs.isPlaceholder(url) else { return nil }
        return try? fs.contents(of: url)
    }

    private func readText(_ url: URL) -> String? {
        readData(url).map { String(decoding: $0, as: UTF8.self) }
    }
}
