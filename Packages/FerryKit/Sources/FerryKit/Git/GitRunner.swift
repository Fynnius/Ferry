import Foundation

/// Runs git with Ferry's contract: the user's shell environment, never
/// interactive, English stderr, lock-free reads, a timeout per command class, and
/// typed errors. One runner is shared by every repo.
public struct GitRunner: Sendable {
    public enum CommandClass: Sendable {
        /// Local read: `--no-optional-locks`, short timeout.
        case read
        /// Local write (add, commit, switch…): takes locks; generous timeout because hooks run.
        case write
        /// Talks to a remote: SSH batch mode unless the user configured ssh themselves.
        case network
    }

    public struct Output: Sendable {
        public var stdout: Data
        public var stderr: String
        public var exitCode: Int32
        public var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    public let installation: GitInstallation
    public let baseEnvironment: [String: String]
    private let limiter: AsyncSemaphore

    public static let sharedLimiter = AsyncSemaphore(permits: 8)

    /// - Parameter askpassPath: an executable git can call for credentials instead of
    ///   hanging on a prompt it can't show. Nil disables prompting entirely.
    public init(installation: GitInstallation, shell: ShellEnvironment, askpassPath: String? = nil, limiter: AsyncSemaphore = GitRunner.sharedLimiter) {
        self.installation = installation
        self.limiter = limiter

        var env = shell.variables
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env.removeValue(forKey: "GIT_DIR")
        env.removeValue(forKey: "GIT_WORK_TREE")
        env.removeValue(forKey: "GIT_INDEX_FILE")
        if let askpassPath {
            env["GIT_ASKPASS"] = askpassPath
            env["SSH_ASKPASS"] = askpassPath
        }
        self.baseEnvironment = env
    }

    public var executable: URL { installation.executable }

    /// Runs `git <arguments>` in `directory` and returns its output, or throws `GitError`.
    @discardableResult
    public func run(
        _ arguments: [String],
        in directory: URL,
        as commandClass: CommandClass = .read,
        stdin: Data? = nil,
        timeout: Duration? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        let output = try await runAllowingFailure(arguments, in: directory, as: commandClass, stdin: stdin, timeout: timeout, onProgress: onProgress)
        guard output.exitCode == 0 else {
            throw GitError(
                kind: GitError.classify(subcommand: Self.subcommand(of: arguments), stderr: output.stderr, stdout: output.text, exitCode: output.exitCode),
                command: arguments,
                exitCode: output.exitCode,
                stderr: output.stderr,
                stdout: output.text
            )
        }
        return output
    }

    /// Like `run`, but returns non-zero exits instead of throwing (for probes such as
    /// `rev-parse --verify`). Still throws on timeout, cancellation and launch failure.
    public func runAllowingFailure(
        _ arguments: [String],
        in directory: URL,
        as commandClass: CommandClass = .read,
        stdin: Data? = nil,
        timeout: Duration? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        var env = baseEnvironment
        var args = arguments
        switch commandClass {
        case .read:
            args.insert("--no-optional-locks", at: 0)
            env["GIT_OPTIONAL_LOCKS"] = "0"
        case .write:
            break
        case .network:
            if env["GIT_SSH_COMMAND"] == nil, env["GIT_SSH"] == nil, await !hasCustomSSHCommand(in: directory) {
                env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
            }
        }

        let request = SubprocessRequest(
            executable: installation.executable,
            arguments: args,
            environment: env,
            currentDirectory: directory,
            stdin: stdin,
            timeout: timeout ?? Self.defaultTimeout(for: commandClass),
            onStderr: onProgress
        )
        let result = try await limiter.withPermit {
            try await Subprocess.run(request)
        }
        if result.cancelled {
            throw GitError(kind: .cancelled, command: arguments, exitCode: result.exitCode, stderr: result.stderrString)
        }
        if result.timedOut {
            throw GitError(kind: .timedOut, command: arguments, exitCode: result.exitCode, stderr: result.stderrString)
        }
        return Output(stdout: result.stdout, stderr: result.stderrString, exitCode: result.exitCode)
    }

    static func defaultTimeout(for commandClass: CommandClass) -> Duration {
        switch commandClass {
        case .read: .seconds(30)
        // Hooks (tests, linters) run inside commit and push; only stop truly stuck processes.
        case .write, .network: .seconds(600)
        }
    }

    static func subcommand(of arguments: [String]) -> String {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "-c" || arg == "-C" { index += 2; continue }
            if arg.hasPrefix("-") { index += 1; continue }
            return arg
        }
        return ""
    }

    private func hasCustomSSHCommand(in directory: URL) async -> Bool {
        let request = SubprocessRequest(
            executable: installation.executable,
            arguments: ["config", "--get", "core.sshCommand"],
            environment: baseEnvironment,
            currentDirectory: directory,
            timeout: .seconds(5)
        )
        guard let result = try? await Subprocess.run(request) else { return false }
        return result.exitCode == 0 && !result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension GitRunner {
    /// Resolves the shell environment and git binary once, for app launch.
    public static func make(configuredGitPath: String? = nil, askpassPath: String? = nil) async throws -> (GitRunner, ShellEnvironment) {
        let shell = await ShellEnvironment.resolve()
        let installation = try await GitLocator.locate(configuredPath: configuredGitPath, environment: shell)
        return (GitRunner(installation: installation, shell: shell, askpassPath: askpassPath), shell)
    }
}
