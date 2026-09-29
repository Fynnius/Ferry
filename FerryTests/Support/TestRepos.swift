import Foundation
@testable import Ferry
import FerryKit

/// Temp repos with an isolated git config and a local bare remote, for app-layer tests.
/// Never touches real repos.
final class TestRepos {
    let root: URL
    let runner: GitRunner

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-app-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("gitconfig")
        try "[user]\n  name = Ferry Tests\n  email = tests@ferry.invalid\n[init]\n  defaultBranch = main\n[commit]\n  gpgsign = false\n"
            .write(to: config, atomically: true, encoding: .utf8)
        let env = ShellEnvironment(
            variables: ["PATH": ShellEnvironment.fallbackPath, "HOME": root.path, "GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1"],
            source: .fallback(reason: "tests")
        )
        let installation = try await GitLocator.locate(configuredPath: nil, environment: env)
        runner = GitRunner(installation: installation, shell: env)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// A clone of a fresh bare remote, wrapped in a RepoItem with its status loaded.
    func clonedItem(_ name: String = "app", app: AppModel? = nil) async throws -> RepoItem {
        let bare = root.appendingPathComponent("\(name).git")
        try await git(["init", "-q", "--bare", bare.path], in: root)
        let seed = root.appendingPathComponent("\(name)-seed")
        try await git(["clone", "-q", bare.path, seed.path], in: root)
        try write("README.md", "# \(name)\n", in: seed)
        try await git(["add", "-A"], in: seed)
        try await git(["commit", "-q", "-m", "Initial commit"], in: seed)
        try await git(["push", "-q", "-u", "origin", "main"], in: seed)
        let dir = root.appendingPathComponent(name)
        try await git(["clone", "-q", bare.path, dir.path], in: root)
        let item = RepoItem(id: dir.path, name: name, path: dir, git: GitRepository(root: dir, runner: runner))
        item.app = app
        await item.refresh()
        return item
    }

    func write(_ path: String, _ contents: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ args: [String], in dir: URL) async throws -> String {
        try await runner.run(args, in: dir, as: .write).text
    }
}
