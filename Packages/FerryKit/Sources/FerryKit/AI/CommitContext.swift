import Foundation

/// Everything the commit-message prompt is built from, gathered from one repo by
/// `GitRepository.commitContext(rules:)`. Secret files carry no content — they were
/// never read.
public struct CommitContext: Sendable, Equatable {
    public var repositoryName: String
    /// Branch name, or nil when HEAD is detached.
    public var branch: String?
    /// Newest first.
    public var recentSubjects: [String]
    /// True when nothing was staged, so the message covers every change (Commit All).
    public var includesAllChanges: Bool
    /// In the order git lists them.
    public var files: [File]

    public init(repositoryName: String, branch: String?, recentSubjects: [String], includesAllChanges: Bool, files: [File]) {
        self.repositoryName = repositoryName
        self.branch = branch
        self.recentSubjects = recentSubjects
        self.includesAllChanges = includesAllChanges
        self.files = files
    }

    public struct File: Sendable, Equatable {
        public enum Change: Sendable, Equatable {
            case added, modified, deleted, typeChanged
            case renamed(from: String)
            case copied(from: String)
        }

        public enum Content: Sendable, Equatable {
            /// Unified diff text for this file, starting at its `diff --git` header.
            case diff(String)
            case binary
            /// Path matched a secret pattern; the file was never opened or diffed.
            case withheldSecret
            case skipped(CommitPromptRules.SkipReason)
            /// A new file over the untracked size limit.
            case tooLarge(bytes: Int)
            /// Not read to stay within the total read limit for untracked files.
            case notRead
            /// No diff available (symlink, directory, submodule, or git reported nothing).
            case unavailable
        }

        public var path: String
        public var change: Change
        public var content: Content

        public init(path: String, change: Change, content: Content) {
            self.path = path
            self.change = change
            self.content = content
        }
    }
}
