import Foundation
import Darwin

/// The user's login-shell environment. GUI apps inherit launchd's bare environment,
/// so without this, hooks that need node/nvm/Homebrew tools fail.
public struct ShellEnvironment: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Read from the user's login shell.
        case loginShell(String)
        /// The shell didn't answer in time or printed nothing usable; a minimal PATH is used.
        case fallback(reason: String)
    }

    public var variables: [String: String]
    public var source: Source

    public init(variables: [String: String], source: Source) {
        self.variables = variables
        self.source = source
    }

    public static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public var path: String { variables["PATH"] ?? Self.fallbackPath }

    /// Resolves the environment by running the login shell once with markers around `env -0`,
    /// so anything a dotfile prints can't be mistaken for the payload.
    public static func resolve(timeout: Duration = .seconds(6), base: [String: String] = ProcessInfo.processInfo.environment) async -> ShellEnvironment {
        let shell = loginShellPath()
        let name = (shell as NSString).lastPathComponent
        let marker = "__FERRY_ENV_\(UUID().uuidString.prefix(8))__"
        let script = "printf '%s' '\(marker)'; /usr/bin/env -0; printf '%s' '\(marker)'"

        let arguments: [String]
        switch name {
        case "bash", "zsh", "sh", "ksh", "dash":
            arguments = ["-ilc", script]
        case "fish":
            arguments = ["-l", "-c", script]
        case "tcsh", "csh":
            arguments = ["-ic", script]
        default:
            return fallback(base: base, reason: "\(name) isn't a supported login shell")
        }

        var env = base
        env["FERRY_RESOLVING_ENVIRONMENT"] = "1"
        // Some prompt frameworks refuse to start without a terminal type.
        env["TERM"] = env["TERM"] ?? "dumb"

        do {
            let result = try await Subprocess.run(SubprocessRequest(
                executable: URL(fileURLWithPath: shell),
                arguments: arguments,
                environment: env,
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser,
                timeout: timeout
            ))
            if result.timedOut {
                return fallback(base: base, reason: "your shell took longer than \(timeout.components.seconds) s to start")
            }
            guard let variables = parse(result.stdout, marker: marker), variables["PATH"] != nil else {
                return fallback(base: base, reason: "your shell didn't report its environment")
            }
            return ShellEnvironment(variables: sanitize(variables), source: .loginShell(shell))
        } catch {
            return fallback(base: base, reason: "\(shell) couldn't be started")
        }
    }

    static func parse(_ data: Data, marker: String) -> [String: String]? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: marker),
              let end = text.range(of: marker, range: start.upperBound..<text.endIndex) else { return nil }
        let payload = text[start.upperBound..<end.lowerBound]
        var variables: [String: String] = [:]
        for entry in payload.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            variables[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return variables.isEmpty ? nil : variables
    }

    /// Drops shell-session noise that shouldn't leak into git child processes.
    static func sanitize(_ variables: [String: String]) -> [String: String] {
        var result = variables
        for key in ["FERRY_RESOLVING_ENVIRONMENT", "SHLVL", "_", "PWD", "OLDPWD", "TERM_SESSION_ID", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"] {
            result.removeValue(forKey: key)
        }
        return result
    }

    static func fallback(base: [String: String], reason: String) -> ShellEnvironment {
        var variables = base
        let existing = base["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        let merged = (fallbackPath.split(separator: ":").map(String.init) + existing).uniqued()
        variables["PATH"] = merged.joined(separator: ":")
        return ShellEnvironment(variables: variables, source: .fallback(reason: reason))
    }

    /// The account's login shell from the user database — not `$SHELL`, which is often
    /// missing or stale for apps launched from Finder or the Dock.
    static func loginShellPath() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
