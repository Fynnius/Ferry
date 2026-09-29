import Foundation
@testable import FerryKit

/// Throwaway repos in a temp dir, with a local bare repo as "remote". Isolated from the
/// developer's git config (global config points at a temp file, system config is off),
/// so signing, hooksPath or aliases on this Mac can't change test outcomes.
/// Never touches real repos.
final class GitFixture: @unchecked Sendable {
    let root: URL
    let runner: GitRunner
    let environment: ShellEnvironment

    static func make(extraConfig: String = "") async throws -> GitFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let globalConfig = root.appendingPathComponent("gitconfig")
        try """
        [user]
            name = Ferry Tests
            email = tests@ferry.invalid
        [init]
            defaultBranch = main
        [commit]
            gpgsign = false
        [advice]
            detachedHead = false
        \(extraConfig)
        """.write(to: globalConfig, atomically: true, encoding: .utf8)

        let variables: [String: String] = [
            "PATH": ShellEnvironment.fallbackPath,
            "HOME": root.path,
            "GIT_CONFIG_GLOBAL": globalConfig.path,
            "GIT_CONFIG_NOSYSTEM": "1",
        ]
        let environment = ShellEnvironment(variables: variables, source: .fallback(reason: "tests"))
        let installation = try await GitLocator.locate(configuredPath: nil, environment: environment)
        return GitFixture(root: root, runner: GitRunner(installation: installation, shell: environment, limiter: AsyncSemaphore(permits: 16)), environment: environment)
    }

    private init(root: URL, runner: GitRunner, environment: ShellEnvironment) {
        self.root = root
        self.runner = runner
        self.environment = environment
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// A bare repo standing in for GitHub, with one commit on `main`.
    func makeRemote(_ name: String = "remote", initialFiles: [String: String] = ["README.md": "# Hello\n"]) async throws -> URL {
        let bare = root.appendingPathComponent("\(name).git")
        try await git(["init", "--bare", "-q", bare.path], in: root)
        let seed = try await makeRepo("\(name)-seed", files: initialFiles)
        try await git(["remote", "add", "origin", bare.path], in: seed.root)
        try await git(["push", "-q", "-u", "origin", "main"], in: seed.root)
        return bare
    }

    /// A clone of `remote` with upstream tracking set up.
    func clone(_ remote: URL, as name: String) async throws -> GitRepository {
        let dir = root.appendingPathComponent(name)
        try await git(["clone", "-q", remote.path, dir.path], in: root)
        return GitRepository(root: dir, runner: runner)
    }

    /// A fresh local repo; with `files`, one initial commit containing them.
    func makeRepo(_ name: String, files: [String: String] = [:]) async throws -> GitRepository {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await git(["init", "-q"], in: dir)
        if !files.isEmpty {
            for (path, contents) in files { try write(path, contents, in: dir) }
            try await git(["add", "-A"], in: dir)
            try await git(["commit", "-q", "-m", "Initial commit"], in: dir)
        }
        return GitRepository(root: dir, runner: runner)
    }

    func write(_ path: String, _ contents: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Commits a change in `repo` and pushes it, as another developer would.
    func commitAndPush(in repo: GitRepository, path: String, contents: String, message: String) async throws {
        try write(path, contents, in: repo.root)
        try await git(["add", "-A"], in: repo.root)
        try await git(["commit", "-q", "-m", message], in: repo.root)
        try await git(["push", "-q"], in: repo.root)
    }

    @discardableResult
    func git(_ arguments: [String], in dir: URL) async throws -> String {
        try await runner.run(arguments, in: dir, as: .write).text
    }

    func installHook(_ name: String, script: String, in repo: GitRepository) throws {
        let hooks = repo.root.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let url = hooks.appendingPathComponent(name)
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
