import Foundation

/// A failed git command, classified from its stderr (always English: we force `LC_ALL=C`).
public struct GitError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `index.lock` exists — another git process is running (terminal, editor, or us).
        case indexLocked
        /// HTTPS remote wants credentials we don't have.
        case authenticationRequired
        /// SSH key rejected or missing.
        case sshKeyRejected
        /// Unknown or changed SSH host key.
        case hostKeyVerificationFailed
        /// GPG/SSH commit signing failed.
        case signingFailed
        /// Remote unreachable: offline, DNS, VPN, timeout.
        case network
        /// Push rejected because the remote has commits we don't.
        case pushRejectedBehind
        /// Server-side hook or branch protection refused the push.
        case pushRejectedByRemote(reason: String)
        /// A local hook (pre-commit, commit-msg, pre-push…) stopped the command.
        case hookFailed
        /// Pushing a branch that has no upstream.
        case noUpstream
        case nothingToCommit
        /// Uncommitted changes would be overwritten by switch/pull/stash apply.
        case localChangesWouldBeOverwritten
        /// Pull with rebase refused because of uncommitted changes.
        case unstagedChangesBlockRebase
        /// The branch is checked out in another worktree.
        case branchCheckedOutElsewhere
        /// The command left or found merge conflicts.
        case conflicts
        /// `git pull` on diverged branches with neither `pull.rebase` nor `pull.ff` configured.
        case divergedNeedsStrategy
        /// Branch deletion refused because it isn't merged.
        case branchNotFullyMerged
        case branchAlreadyExists
        case notARepository
        /// `user.name` / `user.email` aren't configured.
        case identityMissing
        case timedOut
        case cancelled
        case unknown
    }

    public var kind: Kind
    public var command: [String]
    public var exitCode: Int32
    public var stderr: String
    public var stdout: String

    public init(kind: Kind, command: [String], exitCode: Int32, stderr: String, stdout: String = "") {
        self.kind = kind
        self.command = command
        self.exitCode = exitCode
        self.stderr = stderr
        self.stdout = stdout
    }

    /// Everything git printed, trimmed — for "Show details" and hook output sheets.
    public var output: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// One plain-language sentence for the inline error banner.
    public var summary: String {
        switch kind {
        case .indexLocked:
            "Another git operation is running in this repo. Try again in a moment."
        case .authenticationRequired:
            "The remote asked for a sign-in. Check your git credentials for \(remoteHost ?? "this remote")."
        case .sshKeyRejected:
            "\(remoteHost ?? "The server") didn't accept your SSH key. Check your SSH keys or agent."
        case .hostKeyVerificationFailed:
            "\(remoteHost ?? "The server")'s identity couldn't be verified. Check its SSH host key in Terminal."
        case .signingFailed:
            "Commit signing failed. Check your GPG or SSH signing setup."
        case .network:
            "Couldn't reach \(remoteHost ?? "the remote"). Check your connection or VPN."
        case .pushRejectedBehind:
            "The remote has commits you don't have yet. Pull first, then push — or use Sync."
        case .pushRejectedByRemote(let reason):
            "The remote refused the push: \(reason)."
        case .hookFailed:
            "A git hook stopped this. See its output for what to fix."
        case .noUpstream:
            "This branch isn't published yet. Use Publish Branch."
        case .nothingToCommit:
            "There's nothing to commit."
        case .localChangesWouldBeOverwritten:
            "You have uncommitted changes that would be overwritten. Commit or stash them first."
        case .unstagedChangesBlockRebase:
            "Your pull rebases, and that needs a clean working tree. Commit or stash your changes first."
        case .branchCheckedOutElsewhere:
            "That branch is checked out in another worktree."
        case .conflicts:
            "This left merge conflicts. Resolve them in your editor or Terminal, then commit."
        case .divergedNeedsStrategy:
            "Your branch and the remote both have new commits. Choose merge or rebase in Settings → Git."
        case .branchNotFullyMerged:
            "That branch has commits that aren't merged anywhere."
        case .branchAlreadyExists:
            "A branch with that name already exists."
        case .notARepository:
            "This folder isn't a git repository anymore."
        case .identityMissing:
            "Git doesn't know your name and email yet. Set them in Settings → Git."
        case .timedOut:
            "Git didn't finish in time and was stopped."
        case .cancelled:
            "Cancelled."
        case .unknown:
            firstMeaningfulLine ?? "Git failed (exit code \(exitCode))."
        }
    }

    /// The host named in ssh/https errors, e.g. `github.com`.
    public var remoteHost: String? {
        let patterns = [
            #"https?://(?:[^@/\s]+@)?([^/:\s']+)"#,
            #"ssh: connect to host ([^\s]+)"#,
            #"Could not resolve host: ([^\s']+)"#,
            #"git@([^:\s]+):"#,
            #"Host key verification failed.*?([a-z0-9.-]+\.[a-z]{2,})"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
               let range = Range(match.range(at: 1), in: stderr) {
                return String(stderr[range])
            }
        }
        return nil
    }

    private var firstMeaningfulLine: String? {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("hint:") }
            .map { line in
                var text = line
                for prefix in ["fatal: ", "error: "] where text.hasPrefix(prefix) {
                    text = String(text.dropFirst(prefix.count))
                }
                return text.prefix(1).uppercased() + text.dropFirst()
            }
    }
}

extension GitError {
    /// Maps a failed command to a kind. `subcommand` is the git verb (commit, push, …),
    /// which disambiguates generic failures such as hooks.
    static func classify(subcommand: String, stderr: String, stdout: String, exitCode: Int32) -> Kind {
        let err = stderr
        func has(_ needle: String) -> Bool { err.localizedCaseInsensitiveContains(needle) }
        func printed(_ needle: String) -> Bool { has(needle) || stdout.localizedCaseInsensitiveContains(needle) }

        if has("index.lock") && (has("File exists") || has("Another git process")) { return .indexLocked }
        if has("not a git repository") { return .notARepository }
        if has("Please tell me who you are") || has("Author identity unknown") || has("unable to auto-detect email address") { return .identityMissing }
        if has("Host key verification failed") || has("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .hostKeyVerificationFailed }
        if has("Permission denied (publickey") { return .sshKeyRejected }
        if has("could not read Username") || has("could not read Password") || has("Authentication failed")
            || has("terminal prompts disabled") || has("HTTP Basic: Access denied") || has("returned error: 403") {
            return .authenticationRequired
        }
        if has("gpg failed to sign") || has("failed to sign the data") || has("error: Load key") && has("sign") {
            return .signingFailed
        }
        if has("Could not resolve host") || has("Operation timed out") || has("Connection timed out")
            || has("Connection refused") || has("Network is unreachable") || has("Could not read from remote repository") && has("ssh: connect")
            || has("unable to access") && (has("Failed to connect") || has("SSL") || has("timed out")) {
            return .network
        }
        if has("is already used by worktree") || has("is already checked out at") { return .branchCheckedOutElsewhere }
        if has("would be overwritten by") { return .localChangesWouldBeOverwritten }
        if has("cannot pull with rebase") || has("cannot rebase: You have unstaged changes") { return .unstagedChangesBlockRebase }
        if printed("CONFLICT (") || printed("Automatic merge failed") || has("fix conflicts") || has("unmerged files") { return .conflicts }
        if has("Need to specify how to reconcile divergent branches") { return .divergedNeedsStrategy }
        if has("is not fully merged") { return .branchNotFullyMerged }
        if has("already exists") && subcommand == "branch" || has("a branch named") && has("already exists") { return .branchAlreadyExists }
        if has("has no upstream branch") || has("no upstream configured") { return .noUpstream }

        if subcommand == "push" {
            if let reason = remoteRejectionReason(err) { return .pushRejectedByRemote(reason: reason) }
            if has("[rejected]") && (has("non-fast-forward") || has("fetch first")) || has("Updates were rejected because the remote contains work")
                || has("Updates were rejected because the tip of your current branch is behind") {
                return .pushRejectedBehind
            }
            if has("failed to push some refs") && !has("[rejected]") { return .hookFailed }
        }
        if subcommand == "commit" {
            let combined = err + stdout
            if combined.contains("nothing to commit") || combined.contains("no changes added to commit") { return .nothingToCommit }
            // Anything else that stops a commit without a git-authored message comes from a hook.
            if !err.contains("fatal:") && !err.contains("error:") || has("hook") || has("husky") { return .hookFailed }
        }
        if has("hook") && (has("declined") || has("failed") || has("exit") || has("returned")) { return .hookFailed }
        return .unknown
    }

    private static func remoteRejectionReason(_ stderr: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\[remote rejected\][^(]*\(([^)]+)\)"#),
              let match = regex.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
              let range = Range(match.range(at: 1), in: stderr) else { return nil }
        return String(stderr[range])
    }
}
