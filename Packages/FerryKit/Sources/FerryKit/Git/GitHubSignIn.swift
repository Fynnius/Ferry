import Foundation

/// The GitHub CLI (`gh`), which can hand git a token for github.com. Ferry only runs it
/// when the user asks (Connect GitHub CLI) or to answer a prompt git is already showing.
public struct GitHubCLI: Sendable {
    public static let host = "github.com"

    public enum State: Equatable, Sendable {
        case notInstalled
        /// Installed, but `gh auth login` hasn't been run for github.com.
        case signedOut
        case signedIn(account: String?)
    }

    public let executable: URL
    public let environment: [String: String]

    /// Nil when `gh` isn't on the PATH of `environment` (the user's shell environment).
    public init?(environment: [String: String]) {
        guard let executable = Self.find("gh", path: environment["PATH"]) else { return nil }
        self.init(executable: executable, environment: environment)
    }

    public init(executable: URL, environment: [String: String]) {
        self.executable = executable
        var env = environment
        // Never wait for input or print update notices into what Ferry parses.
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        self.environment = env
    }

    /// Whether gh is installed and signed in to github.com. Local only: reads gh's own
    /// config and keychain entry, no network.
    public static func state(environment: [String: String]) async -> State {
        guard let cli = GitHubCLI(environment: environment) else { return .notInstalled }
        return await cli.state()
    }

    public func state() async -> State {
        guard await token() != nil else { return .signedOut }
        return .signedIn(account: await account())
    }

    /// The login gh is signed in with, e.g. `octocat`.
    public func account() async -> String? {
        await output(["config", "get", "user", "--host", Self.host])
    }

    /// gh's token for github.com. Only ever passed straight to git; never stored or logged.
    public func token() async -> String? {
        await output(["auth", "token", "--hostname", Self.host])
    }

    /// `gh auth setup-git --hostname github.com`: makes gh git's credential helper for
    /// GitHub in the user's global git config (`~/.gitconfig`), so Terminal benefits too.
    public func setUpGit() async throws {
        let result = try await Subprocess.run(request(["auth", "setup-git", "--hostname", Self.host]))
        guard result.exitCode == 0, !result.timedOut else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubCLIError(message: message.isEmpty ? "gh auth setup-git failed (exit code \(result.exitCode))." : message)
        }
    }

    /// Trimmed stdout of a successful run, nil on failure or empty output.
    private func output(_ arguments: [String]) async -> String? {
        guard let result = try? await Subprocess.run(request(arguments)), result.exitCode == 0, !result.timedOut else { return nil }
        let text = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func request(_ arguments: [String]) -> SubprocessRequest {
        SubprocessRequest(executable: executable, arguments: arguments, environment: environment, timeout: .seconds(15))
    }

    /// First executable called `name` on a `PATH`-style list.
    public static func find(_ name: String, path: String?) -> URL? {
        for directory in (path ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

public struct GitHubCLIError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }

    public init(message: String) {
        self.message = message
    }
}

/// How git signs in to an HTTPS host: its credential helper, and whether it can get a
/// credential without asking anyone.
public enum CredentialHelper {
    /// `gh auth setup-git` writes `!/path/to/gh auth git-credential`.
    public static func isGitHubCLI(_ helper: String) -> Bool {
        helper.contains("gh auth git-credential")
    }

    /// Whether a remote URL talks to github.com over HTTPS (SSH remotes use keys instead).
    public static func isHTTPSGitHub(_ remoteURL: String) -> Bool {
        guard let components = URLComponents(string: remoteURL),
              components.scheme?.lowercased() == "https" else { return false }
        let host = components.host?.lowercased()
        return host == GitHubCLI.host || host == "www.github.com"
    }

    /// The helper git uses for `url` (`git config --get-urlmatch`, which returns the most
    /// specific entry — gh's `[credential "https://github.com"]` over a global
    /// `osxkeychain`). Nil when none is configured, or the last entry resets the list.
    public static func effective(for url: String, runner: GitRunner, in directory: URL) async -> String? {
        let output = try? await runner.withoutPrompts().runAllowingFailure(["config", "--get-urlmatch", "credential.helper", url], in: directory, timeout: .seconds(10))
        guard let output, output.exitCode == 0 else { return nil }
        return parseHelper(output.text)
    }

    static func parseHelper(_ output: String) -> String? {
        let helper = output.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return helper.isEmpty ? nil : helper
    }

    /// Asks git's helpers for a credential with every prompt disabled (`git credential
    /// fill`). True when one answered — git will fetch and push without asking. Reads
    /// only: nothing is approved, rejected or stored, and the answer is dropped.
    public static func hasStoredCredential(host: String, runner: GitRunner, in directory: URL) async -> Bool {
        let request = Data("protocol=https\nhost=\(host)\n\n".utf8)
        guard let output = try? await runner.withoutPrompts().runAllowingFailure(["credential", "fill"], in: directory, stdin: request, timeout: .seconds(15)),
              output.exitCode == 0 else { return false }
        return output.text.split(separator: "\n").contains { $0.hasPrefix("password=") && $0.count > "password=".count }
    }
}

/// Where the user stands with GitHub over HTTPS, for onboarding and Settings.
public struct GitHubSignInStatus: Equatable, Sendable {
    public var cli: GitHubCLI.State
    /// git's credential helper for https://github.com.
    public var helper: String?
    /// git gets a credential for github.com without asking: fetch and push just work.
    public var hasCredential: Bool

    public init(cli: GitHubCLI.State, helper: String?, hasCredential: Bool) {
        self.cli = cli
        self.helper = helper
        self.hasCredential = hasCredential
    }

    public var usesGitHubCLI: Bool { helper.map(CredentialHelper.isGitHubCLI) ?? false }

    /// Nothing to set up. A helper alone isn't enough: `osxkeychain` may hold nothing for GitHub.
    public var isReady: Bool { hasCredential }

    public static func read(runner: GitRunner, in directory: URL) async -> GitHubSignInStatus {
        async let cli = GitHubCLI.state(environment: runner.baseEnvironment)
        async let helper = CredentialHelper.effective(for: "https://\(GitHubCLI.host)", runner: runner, in: directory)
        async let credential = CredentialHelper.hasStoredCredential(host: GitHubCLI.host, runner: runner, in: directory)
        return await GitHubSignInStatus(cli: cli, helper: helper, hasCredential: credential)
    }
}
