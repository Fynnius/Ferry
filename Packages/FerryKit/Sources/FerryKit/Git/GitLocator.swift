import Foundation

/// A usable git binary and its version.
public struct GitInstallation: Sendable, Equatable {
    public var executable: URL
    public var version: GitVersion
}

public struct GitVersion: Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `git version 2.51.2` or `git version 2.54.0 (Apple Git-157)`.
    public init?(parsing output: String) {
        guard let range = output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        let parts = output[range].split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        self.init(parts[0], parts[1], parts.count > 2 ? parts[2] : 0)
    }

    public static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// Oldest git Ferry supports (`switch`/`restore`, porcelain v2 with stash info).
    public static let minimumSupported = GitVersion(2, 25)
}

public enum GitLocatorError: Error, Equatable, CustomStringConvertible {
    /// No git anywhere, or only Apple's stub that would pop the "install developer tools" dialog.
    case notInstalled
    case configuredPathUnusable(String)
    case tooOld(GitVersion)

    public var description: String {
        switch self {
        case .notInstalled:
            "Git isn't installed. Install the Xcode Command Line Tools (run `xcode-select --install` in Terminal) or Homebrew git."
        case .configuredPathUnusable(let path):
            "The git set in Settings (\(path)) can't be run."
        case .tooOld(let version):
            "Git \(version) is too old — Ferry needs \(GitVersion.minimumSupported) or newer."
        }
    }
}

/// Finds git: the path from Settings, then the shell PATH, then Apple's `/usr/bin/git`
/// only when developer tools are actually installed.
public enum GitLocator {
    public static func locate(configuredPath: String?, environment: ShellEnvironment) async throws -> GitInstallation {
        if let configuredPath, !configuredPath.isEmpty {
            let url = URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath)
            guard let version = await version(of: url, environment: environment) else {
                throw GitLocatorError.configuredPathUnusable(configuredPath)
            }
            return try checked(GitInstallation(executable: url, version: version))
        }

        for directory in environment.path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("git")
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            if candidate.path == "/usr/bin/git", !developerToolsInstalled() { continue }
            if let version = await version(of: candidate, environment: environment) {
                return try checked(GitInstallation(executable: candidate, version: version))
            }
        }

        let appleGit = URL(fileURLWithPath: "/usr/bin/git")
        if developerToolsInstalled(), let version = await version(of: appleGit, environment: environment) {
            return try checked(GitInstallation(executable: appleGit, version: version))
        }
        throw GitLocatorError.notInstalled
    }

    private static func checked(_ installation: GitInstallation) throws -> GitInstallation {
        guard installation.version >= GitVersion.minimumSupported else {
            throw GitLocatorError.tooOld(installation.version)
        }
        return installation
    }

    static func version(of executable: URL, environment: ShellEnvironment) async -> GitVersion? {
        guard let result = try? await Subprocess.run(SubprocessRequest(
            executable: executable,
            arguments: ["--version"],
            environment: environment.variables,
            timeout: .seconds(5)
        )), result.exitCode == 0 else { return nil }
        return GitVersion(parsing: result.stdoutString)
    }

    /// True when Xcode or the Command Line Tools are present, so `/usr/bin/git` is a real
    /// git rather than the stub that shows Apple's install dialog.
    public static func developerToolsInstalled() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git") { return true }
        // `xcode-select -p` reads this link; following it avoids spawning anything.
        if let target = try? fm.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"),
           fm.fileExists(atPath: (target as NSString).appendingPathComponent("usr/bin/git")) {
            return true
        }
        return fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
    }
}
