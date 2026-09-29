import Foundation
import CryptoKit

/// One changed path as git reports it, in one area of the repo.
/// A file can appear twice (staged and unstaged) when it was edited again after `git add`.
public struct FileChange: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case modified, added, deleted, renamed, copied, typeChanged, untracked, conflicted
    }

    public enum Area: String, Hashable, Sendable {
        case staged, unstaged, untracked, conflicted
    }

    public var path: String
    /// The source path of a rename or copy.
    public var originalPath: String?
    public var kind: Kind
    public var area: Area
    /// True when the entry is a submodule rather than a file.
    public var isSubmodule: Bool

    public var id: String { "\(area.rawValue):\(path)" }

    public init(path: String, originalPath: String? = nil, kind: Kind, area: Area, isSubmodule: Bool = false) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.area = area
        self.isSubmodule = isSubmodule
    }

    /// Last path component, e.g. `App.swift` for `Sources/App/App.swift`.
    public var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Everything before the file name, without a trailing slash; empty at the repo root.
    public var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

public struct BranchState: Hashable, Sendable {
    /// Branch name, or nil when HEAD is detached.
    public var head: String?
    /// Commit id of HEAD, or nil in a repo with no commits yet.
    public var oid: String?
    /// Upstream as `remote/branch`, or nil when the branch has none.
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// True when an upstream is configured but its remote ref no longer exists.
    public var upstreamGone: Bool

    public init(head: String?, oid: String?, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, upstreamGone: Bool = false) {
        self.head = head
        self.oid = oid
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.upstreamGone = upstreamGone
    }

    public var isDetached: Bool { head == nil }
    public var hasCommits: Bool { oid != nil }
}

/// A multi-step git operation left in progress in the working tree.
public enum InProgressOperation: String, Hashable, Sendable {
    case merge, rebase, cherryPick, revert, bisect
}

/// How a branch relates to its remote — the five states from gita plus "gone".
public enum SyncState: Hashable, Sendable {
    case noRemote
    case unpublished
    case upstreamGone
    case upToDate
    case ahead(Int)
    case behind(Int)
    case diverged(ahead: Int, behind: Int)
}

/// A point-in-time snapshot of one repository's working tree and branch.
public struct RepoStatus: Hashable, Sendable {
    public var branch: BranchState
    public var staged: [FileChange]
    public var unstaged: [FileChange]
    public var untracked: [FileChange]
    public var conflicted: [FileChange]
    public var stashCount: Int
    public var operation: InProgressOperation?
    public var hasRemote: Bool

    public init(
        branch: BranchState,
        staged: [FileChange] = [],
        unstaged: [FileChange] = [],
        untracked: [FileChange] = [],
        conflicted: [FileChange] = [],
        stashCount: Int = 0,
        operation: InProgressOperation? = nil,
        hasRemote: Bool = true
    ) {
        self.branch = branch
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
        self.stashCount = stashCount
        self.operation = operation
        self.hasRemote = hasRemote
    }

    public var hasChanges: Bool {
        !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty || !conflicted.isEmpty
    }

    /// Number of distinct paths with any change.
    public var changedPathCount: Int {
        Set((staged + unstaged + untracked + conflicted).map(\.path)).count
    }

    public var syncState: SyncState {
        if !hasRemote { return .noRemote }
        if branch.upstream == nil { return .unpublished }
        if branch.upstreamGone { return .upstreamGone }
        switch (branch.ahead, branch.behind) {
        case (0, 0): return .upToDate
        case (let a, 0): return .ahead(a)
        case (0, let b): return .behind(b)
        case (let a, let b): return .diverged(ahead: a, behind: b)
        }
    }

    /// True when the repo needs the user: uncommitted work, unpushed or unpulled commits,
    /// an unpublished branch, or an operation left in progress.
    public var needsAttention: Bool {
        if hasChanges || operation != nil { return true }
        switch syncState {
        case .upToDate, .noRemote: return false
        case .unpublished: return branch.hasCommits
        default: return true
        }
    }
}

extension RepoStatus {
    /// A stable digest of everything Ferry shows for a repo (branch, tracking, files,
    /// stashes, operation). Equal fingerprints mean "nothing changed" — across launches,
    /// unlike `hashValue`. Used to end a snooze as soon as the repo changes.
    public var fingerprint: String {
        var parts = [
            branch.head ?? "(detached)", branch.oid ?? "(initial)", branch.upstream ?? "",
            "\(branch.ahead)", "\(branch.behind)", "\(branch.upstreamGone)",
            "\(stashCount)", operation?.rawValue ?? "", "\(hasRemote)",
        ]
        parts += (staged + unstaged + untracked + conflicted).map { "\($0.id)|\($0.kind.rawValue)|\($0.originalPath ?? "")" }.sorted()
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
