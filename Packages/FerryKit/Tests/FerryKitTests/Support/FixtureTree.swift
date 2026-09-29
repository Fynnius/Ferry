import Foundation
import Synchronization
@testable import FerryKit

// Fixture-tree generator: builds real directory trees with real git repos,
// worktrees and submodules in a temp dir, so discovery tests exercise real FileManager
// and git behaviour. Remote URLs are only strings in each repo's config — nothing is
// ever fetched — and submodule sources are local repos outside the scanned tree.

struct FixtureRepo {
    var name: String
    /// Nil: a local-only repo.
    var remoteURL: String? = nil
    var branch: String = "main"
    var files: [String: String] = [:]
    /// Created with real `git worktree add`, paths relative to the repo.
    var worktrees: [FixtureWorktree] = []
    /// Created with real `git submodule add` from a local source repo.
    var submodules: [FixtureSubmodule] = []
    var monorepo: FixtureMonorepoMarker? = nil
    var bare: Bool = false
    /// Marks the repo's `.git` as a cloud placeholder for `SimulatedCloudFileSystem`.
    var notDownloaded: Bool = false
}

struct FixtureWorktree {
    var path: String
    var branch: String
}

struct FixtureSubmodule {
    var path: String
    var sourceName: String
}

/// `pnpm-workspace.yaml` with real `packages:` globs and matching folders, or the
/// pnpm-10 build-settings-only kind that isn't a monorepo.
enum FixtureMonorepoMarker {
    case pnpm(hasRealPackages: Bool)
}

struct FixturePlainFolder {
    var name: String
    var looseFiles: [String: String] = [:]
}

struct FixtureWorkspaceFile {
    var name: String
    /// As written in the file; may dangle on purpose.
    var folderRefs: [String]
}

indirect enum FixtureNode {
    case dir(String, [FixtureNode])
    case repo(FixtureRepo)
    case plainFolder(FixturePlainFolder)
    case workspaceFile(FixtureWorkspaceFile)
    /// A folder whose contents "live in iCloud" — see `SimulatedCloudFileSystem`.
    case iCloudPlaceholder(name: String)
}

final class FixtureTree: @unchecked Sendable {
    let fixture: GitFixture
    /// Real path of the tree; scan roots go below it.
    let base: URL
    private(set) var placeholders: Set<String> = []

    private init(fixture: GitFixture, base: URL) {
        self.fixture = fixture
        self.base = base
    }

    static func build(_ nodes: [FixtureNode], extraGitConfig: String = "") async throws -> FixtureTree {
        let fixture = try await GitFixture.make(extraConfig: extraGitConfig)
        let dir = fixture.root.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tree = FixtureTree(fixture: fixture, base: canonicalURL(dir)!)
        for node in nodes { try await tree.create(node, in: tree.base) }
        return tree
    }

    /// Real path of `relative` below the tree, as the scanner reports it.
    func url(_ relative: String) -> URL {
        directoryURL(base.appendingPathComponent(relative).path)
    }

    func root(_ relative: String = "", maxDepth: Int = ScanRoot.defaultMaxDepth) -> ScanRoot {
        ScanRoot(url: relative.isEmpty ? base : url(relative), maxDepth: maxDepth)
    }

    /// A scanner wired to this tree: isolated git, simulated cloud state, and the tree
    /// standing in for the home folder so nothing on this Mac is consulted.
    func scanner(readRemotes: Bool = true, home: URL? = nil) -> (RepoScanner, SimulatedCloudFileSystem) {
        let fs = SimulatedCloudFileSystem(placeholders: placeholders)
        let options = RepoScanner.Options(homeDirectory: home ?? base)
        return (RepoScanner(runner: readRemotes ? fixture.runner : nil, options: options, fileSystem: fs), fs)
    }

    func scan(_ roots: [ScanRoot]) async -> ScanResult {
        await scanner().0.scan(roots)
    }

    // MARK: - Building

    private func create(_ node: FixtureNode, in dir: URL) async throws {
        switch node {
        case .dir(let name, let children):
            let url = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for child in children { try await create(child, in: url) }
        case .repo(let repo):
            try await createRepo(repo, in: dir)
        case .plainFolder(let folder):
            let url = dir.appendingPathComponent(folder.name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (path, contents) in folder.looseFiles { try fixture.write(path, contents, in: url) }
        case .workspaceFile(let file):
            let folders = file.folderRefs.map { "    { \"path\": \"\($0)\" }," }.joined(separator: "\n")
            // Written the way VS Code does: comments and trailing commas included.
            try fixture.write(file.name, "{\n  // Saved by VS Code\n  \"folders\": [\n\(folders)\n  ],\n  \"settings\": {},\n}\n", in: dir)
        case .iCloudPlaceholder(let name):
            let url = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try fixture.write("secret.txt", "must never be read\n", in: url)
            placeholders.insert(url.path)
        }
    }

    private func createRepo(_ repo: FixtureRepo, in dir: URL) async throws {
        let url = dir.appendingPathComponent(repo.name, isDirectory: true)
        if repo.bare {
            try await fixture.git(["init", "--bare", "-q", url.path], in: dir)
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try await fixture.git(["init", "-q", "-b", repo.branch], in: url)
        if let remote = repo.remoteURL {
            try await fixture.git(["remote", "add", "origin", remote], in: url)
        }
        var files = repo.files
        files["README.md"] = files["README.md"] ?? "# \(repo.name)\n"
        switch repo.monorepo {
        case .pnpm(hasRealPackages: true)?:
            files["pnpm-workspace.yaml"] = "packages:\n  - 'apps/*'\n  - libs/*  # shared code\n"
            files["apps/web/package.json"] = "{ \"name\": \"web\" }\n"
            files["apps/api/package.json"] = "{ \"name\": \"api\" }\n"
        case .pnpm(hasRealPackages: false)?:
            files["pnpm-workspace.yaml"] = "overrides:\n  semver: ^7.6.0\nonlyBuiltDependencies:\n  - esbuild\n"
        case nil:
            break
        }
        for (path, contents) in files { try fixture.write(path, contents, in: url) }
        try await fixture.git(["add", "-A"], in: url)
        try await fixture.git(["commit", "-q", "-m", "Initial commit"], in: url)

        for worktree in repo.worktrees {
            try await fixture.git(["worktree", "add", "-q", "-b", worktree.branch, worktree.path], in: url)
        }
        for submodule in repo.submodules {
            let source = try await makeSubmoduleSource(submodule.sourceName)
            try await fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", source.path, submodule.path], in: url)
            try await fixture.git(["commit", "-q", "-m", "Add \(submodule.path)"], in: url)
        }
        if repo.notDownloaded {
            placeholders.insert(canonicalURL(url)!.appendingPathComponent(".git").path)
        }
    }

    /// Submodule sources live beside the tree, never inside a scan root.
    private func makeSubmoduleSource(_ name: String) async throws -> URL {
        let url = fixture.root.appendingPathComponent("sources/\(name)", isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try await fixture.git(["init", "-q"], in: url)
        try fixture.write("lib.txt", "shared\n", in: url)
        try await fixture.git(["add", "-A"], in: url)
        try await fixture.git(["commit", "-q", "-m", "Initial commit"], in: url)
        return url
    }
}

/// Real disk, except that chosen paths behave like cloud placeholders. This verifies
/// the scanner's *handling* given those resource values — not real iCloud behaviour,
/// which needs a manual check on a real iCloud Drive folder.
/// It records every listing and read so tests can prove nothing inside a placeholder
/// was touched.
final class SimulatedCloudFileSystem: FileSystemReading {
    private let base = LocalFileSystem()
    private let placeholders: Set<String>
    private let log = Mutex<(listed: [String], read: [String])>(([], []))
    /// Called on every listing, from the scanning task (so it can cancel that task).
    let onList = Mutex<(@Sendable (URL) -> Void)?>(nil)

    init(placeholders: Set<String>) {
        self.placeholders = placeholders
    }

    var listed: [String] { log.withLock { $0.listed } }
    var read: [String] { log.withLock { $0.read } }

    /// Listings or reads of a placeholder or anything inside one — must stay empty.
    var touchedPlaceholders: [String] {
        (listed + read).filter { path in placeholders.contains { path == $0 || path.hasPrefix($0 + "/") } }
    }

    func entries(of directory: URL) throws -> [DirectoryEntry] {
        let path = normalizedPath(directory.path)
        log.withLock { $0.listed.append(path) }
        onList.withLock { $0 }?(directory)
        return try base.entries(of: directory).map { entry in
            var entry = entry
            if placeholders.contains(normalizedPath(directory.appendingPathComponent(entry.name).path)) { entry.isPlaceholder = true }
            return entry
        }
    }

    func isPlaceholder(_ url: URL) -> Bool {
        let path = normalizedPath(url.path)
        return placeholders.contains { path == $0 || path.hasPrefix($0 + "/") } || base.isPlaceholder(url)
    }

    func contents(of file: URL) throws -> Data {
        log.withLock { $0.read.append(normalizedPath(file.path)) }
        return try base.contents(of: file)
    }
}
