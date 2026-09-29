import Foundation

/// What may be sent to the model and how much of it. Every list is a value the app can
/// expose as a setting.
///
/// Patterns are case-insensitive globs. A pattern ending in `/` matches a directory name
/// anywhere in the path (`dist/`), a pattern containing `/` matches the whole path, and
/// anything else matches the file name (`*.pem`).
public struct CommitPromptRules: Sendable, Equatable {
    /// Paths that are never read, diffed or sent — only their name appears in the prompt.
    public var secretPatterns: [String]
    /// File names that match `secretPatterns` but are safe templates (`.env.example`).
    public var secretExceptions: [String]
    /// Dependency lockfiles: listed by name, never diffed.
    public var lockfilePatterns: [String]
    /// Generated, minified or build output: listed by name, never diffed.
    public var generatedPatterns: [String]
    /// Total characters of diff text in the prompt (~4 chars per token → ~7k tokens).
    public var diffBudget: Int
    /// A single file's diff is cut at this many characters and marked `... [diff truncated]`.
    public var perFileLimit: Int
    /// New (untracked) files bigger than this are listed, not read.
    public var untrackedFileSizeLimit: Int
    /// Upper bound on bytes read from untracked files in total, so an unignored
    /// dependency folder can't stall generation. Smallest files are read first.
    public var untrackedTotalReadLimit: Int
    /// Changed-file list lines beyond this collapse into "… and N more files".
    public var maxListedFiles: Int
    /// Recent commit subjects shown for style.
    public var recentSubjectCount: Int
    /// Share of recent subjects that must be Conventional Commits to ask for that style.
    public var conventionalCommitThreshold: Double

    public init(
        secretPatterns: [String] = Self.defaultSecretPatterns,
        secretExceptions: [String] = Self.defaultSecretExceptions,
        lockfilePatterns: [String] = Self.defaultLockfilePatterns,
        generatedPatterns: [String] = Self.defaultGeneratedPatterns,
        diffBudget: Int = 28_000,
        perFileLimit: Int = 8_000,
        untrackedFileSizeLimit: Int = 256 * 1024,
        untrackedTotalReadLimit: Int = 4 * 1024 * 1024,
        maxListedFiles: Int = 300,
        recentSubjectCount: Int = 10,
        conventionalCommitThreshold: Double = 0.7
    ) {
        self.secretPatterns = secretPatterns
        self.secretExceptions = secretExceptions
        self.lockfilePatterns = lockfilePatterns
        self.generatedPatterns = generatedPatterns
        self.diffBudget = diffBudget
        self.perFileLimit = perFileLimit
        self.untrackedFileSizeLimit = untrackedFileSizeLimit
        self.untrackedTotalReadLimit = untrackedTotalReadLimit
        self.maxListedFiles = maxListedFiles
        self.recentSubjectCount = recentSubjectCount
        self.conventionalCommitThreshold = conventionalCommitThreshold
    }

    public static let `default` = CommitPromptRules()

    public static let defaultSecretPatterns = [
        ".env*",
        "*.pem", "*.key", "*.p12", "*.pfx", "*.cer", "*.crt",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "*.ppk",
        "*credentials*", "*secrets*",
        ".npmrc", ".pypirc",
        "google-services.json", "GoogleService-Info.plist",
        ".git/",
    ]

    public static let defaultSecretExceptions = [".env.example", ".env.sample"]

    public static let defaultLockfilePatterns = [
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
        "Podfile.lock", "Package.resolved", "Cargo.lock", "poetry.lock", "Gemfile.lock",
        "*.lock", "*-lock.json", "*-lock.yaml",
    ]

    public static let defaultGeneratedPatterns = [
        "*.min.js", "*.min.css", "*.generated.swift",
        "dist/", "build/", ".build/", "DerivedData/",
    ]

    /// Why a file's contents stay out of the prompt even though it isn't a secret.
    public enum SkipReason: String, Sendable, Equatable {
        case lockfile, generated
    }

    /// True when the path looks like it holds credentials. Checked before anything reads the file.
    public func isSecret(_ path: String) -> Bool {
        let name = Self.fileName(of: path)
        if secretExceptions.contains(where: { Self.glob($0, name) }) { return false }
        return secretPatterns.contains { Self.matches($0, path: path) }
    }

    public func skipReason(for path: String) -> SkipReason? {
        if lockfilePatterns.contains(where: { Self.matches($0, path: path) }) { return .lockfile }
        if generatedPatterns.contains(where: { Self.matches($0, path: path) }) { return .generated }
        return nil
    }

    static func matches(_ pattern: String, path: String) -> Bool {
        if pattern.hasSuffix("/") {
            let directory = String(pattern.dropLast())
            return path.split(separator: "/").dropLast().contains { glob(directory, String($0)) }
        }
        if pattern.contains("/") { return glob(pattern, path) }
        return glob(pattern, fileName(of: path))
    }

    static func fileName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func glob(_ pattern: String, _ string: String) -> Bool {
        fnmatch(pattern, string, FNM_CASEFOLD) == 0
    }
}
