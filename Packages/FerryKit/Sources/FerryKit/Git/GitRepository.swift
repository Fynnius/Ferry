import Foundation
import Synchronization

/// One working tree and everything Ferry does to it. Reads run concurrently;
/// writes go through a per-repo serial queue so they never race for `index.lock`.
public final class GitRepository: Sendable {
    public let root: URL
    public let runner: GitRunner
    private let writes = SerialExecutor()
    private let cachedGitDir = Mutex<URL?>(nil)

    public init(root: URL, runner: GitRunner) {
        self.root = root.standardizedFileURL
        self.runner = runner
    }

    // MARK: - Reading

    /// Full status snapshot: files, branch, ahead/behind, stash count, remotes, in-progress op.
    public func status() async throws -> RepoStatus {
        let output = try await runner.run(["status", "--porcelain=v2", "-z", "--branch", "--show-stash", "--untracked-files=all"], in: root)
        var status = StatusParser.parse(output.stdout)
        if status.branch.upstream == nil {
            status.hasRemote = try await !remotes().isEmpty
        }
        status.operation = try await inProgressOperation()
        return status
    }

    /// Names of configured remotes, e.g. `["origin"]`.
    public func remotes() async throws -> [String] {
        try await runner.run(["remote"], in: root).text
            .split(separator: "\n").map(String.init)
    }

    /// Fetch URL of a remote, nil when it doesn't exist.
    public func remoteURL(_ name: String = "origin") async throws -> String? {
        let output = try await runner.runAllowingFailure(["remote", "get-url", name], in: root)
        guard output.exitCode == 0 else { return nil }
        let url = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    public func gitDirectory() async throws -> URL {
        if let dir = cachedGitDir.withLock({ $0 }) { return dir }
        let path = try await runner.run(["rev-parse", "--absolute-git-dir"], in: root).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: path)
        cachedGitDir.withLock { $0 = url }
        return url
    }

    /// The operation left in progress, detected from marker files in the git dir.
    public func inProgressOperation() async throws -> InProgressOperation? {
        let dir = try await gitDirectory()
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        if exists("BISECT_LOG") { return .bisect }
        return nil
    }

    public func hasCommits() async throws -> Bool {
        try await runner.runAllowingFailure(["rev-parse", "-q", "--verify", "HEAD"], in: root).exitCode == 0
    }

    public func configValue(_ key: String) async throws -> String? {
        let output = try await runner.runAllowingFailure(["config", "--get", key], in: root)
        guard output.exitCode == 0 else { return nil }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Full message of the last commit.
    public func lastCommitMessage() async throws -> String {
        try await runner.run(["log", "-1", "--format=%B"], in: root).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Subjects of the most recent commits on HEAD, newest first (AI style reference).
    public func recentSubjects(limit: Int = 10) async throws -> [String] {
        guard try await hasCommits() else { return [] }
        return try await runner.run(["log", "-\(limit)", "--format=%s"], in: root).text
            .split(separator: "\n").map(String.init)
    }

    // MARK: - Staging

    public func stage(_ files: [FileChange]) async throws {
        let paths = files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        guard !paths.isEmpty else { return }
        try await writeGit(["add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"], stdin: Self.nulList(paths))
    }

    public func stageAll() async throws {
        try await writeGit(["add", "-A"])
    }

    public func unstage(_ files: [FileChange]) async throws {
        let paths = files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        guard !paths.isEmpty else { return }
        if try await hasCommits() {
            try await writeGit(["restore", "--staged", "--pathspec-from-file=-", "--pathspec-file-nul"], stdin: Self.nulList(paths))
        } else {
            try await writeGit(["rm", "--cached", "-r", "-q", "--pathspec-from-file=-", "--pathspec-file-nul"], stdin: Self.nulList(paths))
        }
    }

    public func unstageAll() async throws {
        if try await hasCommits() {
            try await writeGit(["reset", "-q"])
        } else {
            try await writeGit(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "."])
        }
    }

    // MARK: - Committing

    /// Commits the staged changes. With `all`, stages everything first (Commit All) and,
    /// if the commit fails, unstages again so the repo is left exactly as it was.
    public func commit(message: String, all: Bool = false, amend: Bool = false) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        try await writes.run { [self] in
            if all {
                try await runner.run(["add", "-A"], in: root, as: .write)
            }
            do {
                var args = ["commit"]
                if amend { args.append("--amend") }
                if trimmed.isEmpty && amend {
                    args.append("--no-edit")
                    try await runner.run(args, in: root, as: .write)
                } else {
                    args += ["-F", "-"]
                    try await runner.run(args, in: root, as: .write, stdin: Data(trimmed.utf8))
                }
            } catch {
                if all { try? await unstageAllUnqueued() }
                throw error
            }
        }
    }

    /// Undoes the last commit, keeping its changes staged, and returns its message so
    /// the UI can put it back in the field. Callers must only offer this for unpushed commits.
    @discardableResult
    public func undoLastCommit() async throws -> String {
        let message = try await lastCommitMessage()
        try await writes.run { [self] in
            let hasParent = try await runner.runAllowingFailure(["rev-parse", "-q", "--verify", "HEAD~1"], in: root).exitCode == 0
            if hasParent {
                try await runner.run(["reset", "--soft", "HEAD~1"], in: root, as: .write)
            } else {
                // Root commit: drop the branch ref; the index keeps the files staged.
                try await runner.run(["update-ref", "-d", "HEAD"], in: root, as: .write)
            }
        }
        return message
    }

    // MARK: - Remote operations

    /// - Parameter allowPrompts: false for background fetches: a missing credential fails
    ///   as `authenticationRequired` instead of showing a sign-in dialog.
    public func fetch(timeout: Duration? = nil, allowPrompts: Bool = true, onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        let runner = allowPrompts ? runner : runner.withoutPrompts()
        try await runner.run(["fetch", "--progress"], in: root, as: .network, timeout: timeout, onProgress: onProgress)
    }

    /// How to reconcile diverged branches when the user's git config doesn't say.
    public enum PullStrategy: String, Sendable, CaseIterable {
        case merge, rebase
    }

    /// Pulls with the user's `pull.rebase`/`pull.ff`. Only when neither is set — where
    /// modern git refuses to pull diverged branches — Ferry passes `fallback` explicitly.
    public func pull(fallback: PullStrategy = .merge, onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        var args = ["pull", "--progress"]
        if try await configValue("pull.rebase") == nil, try await configValue("pull.ff") == nil {
            args.append(fallback == .rebase ? "--rebase" : "--no-rebase")
        }
        try await writes.run { [self, args] in
            try await runner.run(args, in: root, as: .network, onProgress: onProgress)
        }
    }

    public func push(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await writes.run { [self] in
            try await runner.run(["push", "--progress"], in: root, as: .network, onProgress: onProgress)
        }
    }

    /// Pushes the current branch and sets its upstream. Picks `origin`, else the only remote.
    public func publish(remote: String? = nil, onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        let status = try await status()
        guard let branch = status.branch.head else {
            throw GitError(kind: .unknown, command: ["push"], exitCode: 1, stderr: "fatal: You are not currently on a branch.")
        }
        var target = remote
        if target == nil { target = try await preferredRemote() }
        guard let target else {
            throw GitError(kind: .unknown, command: ["push"], exitCode: 1, stderr: "fatal: This repository has no remote to publish to.")
        }
        try await writes.run { [self] in
            try await runner.run(["push", "--progress", "--set-upstream", target, branch], in: root, as: .network, onProgress: onProgress)
        }
    }

    /// Pull, then push if there's anything to push — VS Code's Sync. Pull honours the
    /// user's `pull.rebase`/`pull.ff`; nothing is overridden.
    public func sync(fallback: PullStrategy = .merge, onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await pull(fallback: fallback, onProgress: onProgress)
        let after = try await status()
        if after.branch.ahead > 0 {
            try await push(onProgress: onProgress)
        }
    }

    public func preferredRemote() async throws -> String? {
        let names = try await remotes()
        return names.contains("origin") ? "origin" : names.first
    }

    // MARK: - Internals

    /// Runs `operation` on this repo's serial write queue.
    @discardableResult
    func serialWrite<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await writes.run(operation)
    }

    private func unstageAllUnqueued() async throws {
        if try await hasCommits() {
            try await runner.run(["reset", "-q"], in: root, as: .write)
        } else {
            try await runner.run(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "."], in: root, as: .write)
        }
    }

    static func nulList(_ paths: [String]) -> Data {
        Data(paths.joined(separator: "\0").utf8) + Data([0])
    }
}
