import Foundation

/// Stable identity of a repo across copies and rescans: its normalised remote, or its
/// path when it has no remote. Overrides are keyed by this, so they survive rescans.
public struct RepoID: Hashable, Comparable, Sendable, Codable, CodingKeyRepresentable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(remote: RemoteIdentity?, path: String) {
        self.init(remote.map(\.key) ?? "path:\(path)")
    }

    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var codingKey: any CodingKey { StringKey(rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(codingKey.stringValue) }
    public static func < (lhs: RepoID, rhs: RepoID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// Identity of a project. Suggested projects are keyed by the signal that formed them
/// (`workspace:<file>`, `folder:<path>`, `org:<owner>/<stem>`), so a rescan that finds the
/// same signal produces the same id and the user's rename or moves still apply.
public struct ProjectID: Hashable, Comparable, Sendable, Codable, CodingKeyRepresentable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Target for "move to Other Repositories".
    public static let other = ProjectID("other")

    public static func userCreated(_ uuid: UUID = UUID()) -> ProjectID { ProjectID("user:\(uuid.uuidString)") }

    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var codingKey: any CodingKey { StringKey(rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(codingKey.stringValue) }
    public static func < (lhs: ProjectID, rhs: ProjectID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

struct StringKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Two repos the user said don't belong together. Order doesn't matter.
public struct RepoPair: Hashable, Sendable, Codable {
    public let first: RepoID
    public let second: RepoID

    public init(_ a: RepoID, _ b: RepoID) {
        (first, second) = a <= b ? (a, b) : (b, a)
    }

    public func contains(_ id: RepoID) -> Bool { first == id || second == id }
}

/// One local checkout of a repo, with the worktrees and submodules that hang off it.
public struct RepoCopy: Hashable, Sendable {
    public var repo: DiscoveredRepo
    public var worktrees: [DiscoveredRepo]
    public var submodules: [DiscoveredRepo]

    public init(repo: DiscoveredRepo, worktrees: [DiscoveredRepo] = [], submodules: [DiscoveredRepo] = []) {
        self.repo = repo
        self.worktrees = worktrees
        self.submodules = submodules
    }

    public var url: URL { repo.url }
}

/// A repo as the user thinks of it: one identity, possibly cloned more than once.
/// Duplicates are copies here, never separate repos.
public struct RepoEntry: Hashable, Sendable, Identifiable {
    public var id: RepoID
    public var remote: RemoteIdentity?
    /// Primary copy first: the one Ferry shows and operates on.
    public var copies: [RepoCopy]
    public var isPinned: Bool
    /// The user put this repo in its project (a move override), rather than a heuristic.
    public var isPlacedByUser: Bool

    public init(id: RepoID, remote: RemoteIdentity?, copies: [RepoCopy], isPinned: Bool = false, isPlacedByUser: Bool = false) {
        self.id = id
        self.remote = remote
        self.copies = copies
        self.isPinned = isPinned
        self.isPlacedByUser = isPlacedByUser
    }

    public var primary: RepoCopy { copies[0] }
    /// The folder name, as the user sees it in Finder and their editor.
    public var name: String { primary.url.lastPathComponent }
    public var hasDuplicates: Bool { copies.count > 1 }
    public var isMonorepo: Bool { primary.repo.monorepo != nil }

    /// "2 copies on this Mac (same remote)" — nil when there's only one.
    public var duplicateSummary: String? {
        hasDuplicates ? "\(copies.count) copies on this Mac (same remote)" : nil
    }
}

/// Why repos were grouped, phrased for the "why grouped" line in the review screen.
public enum GroupingReason: Hashable, Sendable {
    case workspaceFile(fileName: String)
    case sameOwnerInFolder(host: String, owner: String, folder: String)
    /// ghq-style `<host>/<owner>/<repo>` folders that mirror the remotes.
    case hostOwnerLayout(host: String, owner: String)
    case sameOwnerAndStem(host: String, owner: String, stem: String)
    case foundTogether(folder: String)
    case createdByUser

    public var summary: String {
        switch self {
        case .workspaceFile(let fileName):
            "From \(fileName)"
        case .sameOwnerInFolder(let host, let owner, let folder):
            "\(Self.sameOwner(host: host, owner: owner)) · all in \(folder)/"
        case .hostOwnerLayout(let host, let owner):
            "Matches your \(host)/\(owner)/… folder layout"
        case .sameOwnerAndStem(let host, let owner, let stem):
            "\(Self.sameOwner(host: host, owner: owner)) · names start with “\(stem)”"
        case .foundTogether(let folder):
            "All found together in \(folder)/"
        case .createdByUser:
            "Created by you"
        }
    }

    var rank: Int {
        switch self {
        case .createdByUser: 0
        case .workspaceFile: 1
        case .sameOwnerInFolder, .hostOwnerLayout: 2
        case .sameOwnerAndStem: 3
        case .foundTogether: 4
        }
    }

    private static func sameOwner(host: String, owner: String) -> String {
        let identity = RemoteIdentity(host: host, owner: owner, name: "")
        return identity.hostDisplayName == host ? "Same owner on \(host): \(owner)" : "Same \(identity.hostDisplayName) org: \(owner)"
    }
}

/// A group of repos shown together in the sidebar.
public struct Project: Hashable, Sendable, Identifiable {
    public var id: ProjectID
    /// Ids of every signal merged into this project; overrides match any of them, so a
    /// rename survives when a weaker signal becomes the strongest one left.
    public var aliases: [ProjectID]
    public var name: String
    /// Strongest first.
    public var reasons: [GroupingReason]
    public var repos: [RepoEntry]
    public var isUserCreated: Bool

    public init(id: ProjectID, aliases: [ProjectID] = [], name: String, reasons: [GroupingReason], repos: [RepoEntry], isUserCreated: Bool = false) {
        self.id = id
        self.aliases = aliases.isEmpty ? [id] : aliases
        self.name = name
        self.reasons = reasons
        self.repos = repos
        self.isUserCreated = isUserCreated
    }

    /// One line for the UI: the strongest reason.
    public var why: String { reasons.first?.summary ?? "" }
}

/// The full picture: projects, repos no signal placed, and repos the user hid.
public struct Grouping: Hashable, Sendable {
    /// Name of the bucket for repos that fit no project — plain words, no jargon.
    public static let otherTitle = "Other Repositories"
    public static let otherWhy = "No shared workspace file, folder or org found"

    public var projects: [Project]
    public var other: [RepoEntry]
    /// Hidden by the user; kept so Settings can list and restore them.
    public var hidden: [RepoEntry]

    public init(projects: [Project] = [], other: [RepoEntry] = [], hidden: [RepoEntry] = []) {
        self.projects = projects
        self.other = other
        self.hidden = hidden
    }

    /// Every visible repo, projects first.
    public var visibleRepos: [RepoEntry] { projects.flatMap(\.repos) + other }

    public func project(containing id: RepoID) -> Project? {
        projects.first { $0.repos.contains { $0.id == id } }
    }
}
