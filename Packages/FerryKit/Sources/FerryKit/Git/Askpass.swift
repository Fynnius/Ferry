import Foundation
import Darwin

/// What git (or ssh) is asking for when it runs the askpass helper. Git asks in two
/// separate runs — "Username for 'https://github.com': ", then
/// "Password for 'https://user@github.com': " — and skips the first when the remote URL
/// already carries a username.
public struct CredentialPrompt: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case username
        case password
        /// An SSH key's passphrase.
        case passphrase
        /// Anything else (e.g. ssh's host-key question): shown as written.
        case other
    }

    public var kind: Kind
    /// The host being signed in to, e.g. `github.com`; nil when the prompt doesn't name one.
    public var host: String?
    /// The username already known for this host (from the URL in a password prompt).
    public var username: String?
    /// The prompt exactly as git passed it.
    public var text: String

    public init(_ text: String) {
        self.text = text
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("username for") {
            kind = .username
        } else if lower.hasPrefix("password for") || lower.hasSuffix("password:") {
            kind = .password
        } else if lower.contains("passphrase") {
            kind = .passphrase
        } else {
            kind = .other
        }
        if let url = Self.quotedURL(in: text), let components = URLComponents(string: url) {
            host = components.host?.lowercased()
            username = components.user.flatMap { $0.removingPercentEncoding ?? $0 }
        } else if kind == .password, let match = text.range(of: #"[A-Za-z0-9._-]+@[A-Za-z0-9.-]+"#, options: .regularExpression) {
            // ssh: "user@host's password:" or "(user@host) Password:".
            let pair = text[match].split(separator: "@", maxSplits: 1)
            username = String(pair[0])
            host = String(pair[1]).lowercased()
        }
    }

    /// GitHub.com, where passwords stopped working for git in 2021.
    public var isGitHub: Bool { host == GitHubCLI.host || host == "www.github.com" }

    /// What a cancel is remembered by: the host, else the whole prompt (an SSH key).
    public var cancelKey: String { host ?? text }

    private static func quotedURL(in text: String) -> String? {
        guard let range = text.range(of: #"'[a-z][a-z0-9+.-]*://[^']+'"#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst().dropLast())
    }
}

/// Keeps credential prompts calm across the separate askpass processes git starts:
/// one dialog at a time (a file lock the next prompt waits on), and after the user
/// cancels a prompt for a host, the prompts that were queued behind it — and any others
/// for that host within `cancelWindow` — answer "no" without a dialog.
public struct AskpassGate: Sendable {
    public static let cancelWindow: TimeInterval = 60

    public let directory: URL

    public init(directory: URL = AskpassGate.defaultDirectory) {
        self.directory = directory
    }

    /// Per-user temp folder, shared by the app and every askpass process it causes.
    public static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("io.github.fynnius.Ferry.askpass", isDirectory: true)
    }

    /// Runs `body` while holding the prompt lock; waits for any other prompt first.
    /// Without a lock file (unwritable temp dir) it runs anyway: a second dialog beats a hang.
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        prepareDirectory()
        let fd = open(directory.appendingPathComponent("prompt.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0, errno == EINTR {}
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    public func wasCancelledRecently(_ key: String, now: Date = .now) -> Bool {
        guard let text = try? String(contentsOf: cancelFile(key), encoding: .utf8),
              let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let age = now.timeIntervalSince1970 - seconds
        return age >= 0 && age < Self.cancelWindow
    }

    public func recordCancel(_ key: String, now: Date = .now) {
        prepareDirectory()
        try? String(now.timeIntervalSince1970).write(to: cancelFile(key), atomically: true, encoding: .utf8)
    }

    /// The user asked for this one (clicked Push, Sign In…): an earlier cancel no longer applies.
    public func forgetCancellations() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("cancelled-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func cancelFile(_ key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "prompt"
        return directory.appendingPathComponent("cancelled-" + String(safe.prefix(200)))
    }

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
