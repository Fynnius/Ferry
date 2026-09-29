import Foundation

/// Turns a scan into suggested projects. Pure: no disk, no git — everything
/// it needs is in the `ScanResult`, so every rule is unit-testable on plain values.
///
/// Rules, strongest first. Each rule proposes clusters of repo identities;
/// overlapping clusters merge, and a merged project takes its id, name and first
/// "why" from its strongest cluster.
///
/// - **Duplicates first**: the same normalised remote in several places is one repo
///   with several copies, never two repos. Because clusters hold identities, copies in
///   two trees also join the projects those trees form.
/// - **Workspace file**: a `.code-workspace` whose folder entries resolve to at least
///   two found repos. Dangling entries and non-repo folders are ignored; a file naming
///   a single repo says nothing about grouping, so it's ignored too.
/// - **Same owner in a project folder**: two or more repos directly inside one folder
///   that isn't a container (below), all with the same remote owner. ghq's
///   `host/owner/repo` layout is this rule with its own "why".
/// - **Same owner + name stem**: repos of one owner whose names start with the same
///   word (`harbor-app`, `harbor-admin`), wherever they are on disk.
/// - **Found together**: as the folder rule, but with mixed or missing owners.
/// - **Name variants**, last and only among repos nothing above placed: names that are
///   one another plus punctuation or a new word (`Lighthouse` / `Lighthouse-dev`), at
///   least `variantMinimumLength` letters long. See `variantProjects`.
///
/// Never a signal on its own: names that merely start alike without a shared owner, and
/// the owner alone. A personal account typically owns dozens of unrelated repos and nothing
/// offline tells it from an organisation, so the owner only counts when a folder or a
/// name stem backs it up.
///
/// Container folders never group their contents, because being in them says nothing
/// about how repos relate: the scan roots, the home folder and its direct children
/// (`~/Developer`, `~/Projects`…), conventional clone shelves by name (`GitHub`,
/// `repos`, `src`…), and any folder with more than `largeFolderLimit` repos whose names
/// don't mostly share a stem (a shelf of unrelated clones, not a product).
///
/// Worktrees and submodules attach to their parent's copy. Repos no rule places go to
/// "Other Repositories".
public struct ProjectGrouper: Sendable {
    public var homeDirectory: URL?
    public var containerFolderNames: Set<String>
    public var largeFolderLimit: Int

    public static let defaultContainerFolderNames: Set<String> = [
        "developer", "projects", "code", "src", "source", "dev", "repos", "repositories",
        "git", "github", "gitlab", "bitbucket", "workspace", "workspaces", "sites", "clones",
        "documents", "desktop", "downloads",
    ]

    public init(
        homeDirectory: URL? = FileManager.default.homeDirectoryForCurrentUser,
        containerFolderNames: Set<String> = ProjectGrouper.defaultContainerFolderNames,
        largeFolderLimit: Int = 8
    ) {
        self.homeDirectory = homeDirectory
        self.containerFolderNames = containerFolderNames
        self.largeFolderLimit = largeFolderLimit
    }

    /// - Parameter keepingApart: pairs the user marked "not related"; no suggested
    ///   project will contain both. Stronger rules claim repos first, so the repo that
    ///   gets left out is the one joined by the weaker signal.
    public func group(_ scan: ScanResult, keepingApart notRelated: Set<RepoPair> = []) -> Grouping {
        let entries = Self.entries(from: scan)
        let clusters = self.clusters(entries: entries, scan: scan).sorted { a, b in
            (a.reason.rank, -a.members.count, a.key) < (b.reason.rank, -b.members.count, b.key)
        }

        var sets = DisjointSets(entries.map(\.id), notRelated: notRelated)
        var anchors: [(Cluster, RepoID)] = []
        for cluster in clusters {
            let members = cluster.members.sorted()
            // Anchor on the member already in the biggest group, so a stronger rule's
            // group grows instead of being split by a weaker one.
            guard let anchor = members.max(by: { (sets.size(of: $0), $1) < (sets.size(of: $1), $0) }) else { continue }
            for member in members where member != anchor { sets.union(anchor, member) }
            anchors.append((cluster, anchor))
        }

        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var contributions: [RepoID: [Cluster]] = [:]
        for (cluster, anchor) in anchors {
            let root = sets.find(anchor)
            if cluster.members.filter({ sets.find($0) == root }).count >= 2 {
                contributions[root, default: []].append(cluster)
            }
        }

        var projects: [Project] = []
        var grouped: Set<RepoID> = []
        for (root, contributing) in contributions {
            let members = sets.members(of: root)
            guard members.count >= 2, let strongest = contributing.first else { continue }
            grouped.formUnion(members)
            var reasons: [GroupingReason] = []
            for cluster in contributing where !reasons.contains(cluster.reason) { reasons.append(cluster.reason) }
            projects.append(Project(
                id: strongest.key,
                aliases: contributing.map(\.key),
                name: strongest.name,
                reasons: reasons,
                repos: Self.sortedRepos(members.compactMap { byID[$0] })
            ))
        }
        for project in Self.variantProjects(entries.filter { !grouped.contains($0.id) }, notRelated: notRelated) {
            grouped.formUnion(project.repos.map(\.id))
            projects.append(project)
        }
        return Grouping(
            projects: Self.sortedProjects(projects),
            other: Self.sortedRepos(entries.filter { !grouped.contains($0.id) })
        )
    }

    // MARK: - Identities

    /// One entry per identity, worktrees and submodules attached, primary copy first.
    static func entries(from scan: ScanResult) -> [RepoEntry] {
        let byPath = Dictionary(scan.repos.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        /// The working repo a worktree or submodule ultimately belongs to, if it was found.
        func anchor(of repo: DiscoveredRepo) -> DiscoveredRepo? {
            var current = repo
            var visited: Set<String> = [repo.path]
            while true {
                let parentPath: String
                switch current.kind {
                case .repository: return current.path == repo.path ? nil : current
                case .worktree(let parent, _), .submodule(let parent): parentPath = parent.path
                }
                guard let parent = byPath[parentPath], visited.insert(parentPath).inserted else { return nil }
                current = parent
            }
        }

        var copies: [String: RepoCopy] = [:]
        var attached: [(DiscoveredRepo, String)] = []
        for repo in scan.repos {
            if repo.kind != .repository, let parent = anchor(of: repo) {
                attached.append((repo, parent.path))
            } else {
                // Working repos, plus worktrees/submodules whose parent wasn't found
                // (e.g. worktrees of a bare clone): shown as repos so they aren't lost.
                copies[repo.path] = RepoCopy(repo: repo)
            }
        }
        for (child, parentPath) in attached {
            if case .worktree = child.kind { copies[parentPath]?.worktrees.append(child) } else { copies[parentPath]?.submodules.append(child) }
        }

        let inWorkspace = Set(scan.workspaceFiles.flatMap { $0.folders.map(\.path) })
        let siblings = Dictionary(grouping: copies.values, by: { $0.url.deletingLastPathComponent().path }).mapValues(\.count)

        var byID: [RepoID: [RepoCopy]] = [:]
        for copy in copies.values {
            byID[RepoID(remote: copy.repo.remote, path: copy.repo.path), default: []].append(copy)
        }
        return byID.map { id, copies in
            // Default primary: downloaded, then named in a workspace file, then the copy
            // among the most other repos (the more complete tree), then path order.
            func score(_ c: RepoCopy) -> (Int, Int, Int, String) {
                (c.repo.isDownloaded ? 0 : 1, inWorkspace.contains(c.url.path) ? 0 : 1, -(siblings[c.url.deletingLastPathComponent().path] ?? 0), c.url.path)
            }
            let ordered = copies.sorted { score($0) < score($1) }
            return RepoEntry(id: id, remote: ordered[0].repo.remote, copies: ordered)
        }.sorted { $0.id < $1.id }
    }

    // MARK: - Clusters

    struct Cluster {
        var key: ProjectID
        var name: String
        var reason: GroupingReason
        var members: Set<RepoID>
    }

    private func clusters(entries: [RepoEntry], scan: ScanResult) -> [Cluster] {
        var idByPath: [String: RepoID] = [:]
        for entry in entries {
            for copy in entry.copies {
                idByPath[copy.url.path] = entry.id
                for child in copy.worktrees + copy.submodules { idByPath[child.path] = entry.id }
            }
        }
        var result: [Cluster] = []

        // 1. Workspace files.
        for file in scan.workspaceFiles {
            let members = Set(file.folders.compactMap { idByPath[$0.path] })
            guard members.count >= 2 else { continue }
            result.append(Cluster(key: ProjectID("workspace:\(file.url.path)"), name: file.name, reason: .workspaceFile(fileName: file.url.lastPathComponent), members: members))
        }

        // 4. Same owner + name stem.
        var byOwnerStem: [String: [RepoEntry]] = [:]
        for entry in entries {
            guard let remote = entry.remote, let owner = remote.ownerKey, let stem = Self.stem(of: remote.name) else { continue }
            byOwnerStem["\(owner)/\(stem.key)", default: []].append(entry)
        }
        for (key, members) in byOwnerStem where members.count >= 2 {
            let first = members.min { $0.id < $1.id }!
            let remote = first.remote!
            let stem = Self.stem(of: remote.name)!.display
            result.append(Cluster(key: ProjectID("org:\(key)"), name: stem, reason: .sameOwnerAndStem(host: remote.host, owner: remote.owner, stem: stem), members: Set(members.map(\.id))))
        }

        // 5. Shared project folder (and 3: same owner in it; ghq layout).
        var byFolder: [String: [RepoEntry]] = [:]
        for entry in entries {
            for folder in Set(entry.copies.map { $0.url.deletingLastPathComponent().path }) {
                byFolder[folder, default: []].append(entry)
            }
        }
        let rootPaths = Set(scan.roots.map { $0.url.path })
        for (folder, members) in byFolder where members.count >= 2 && !isContainer(folder, members: members, rootPaths: rootPaths) {
            let name = (folder as NSString).lastPathComponent
            result.append(Cluster(key: ProjectID("folder:\(folder)"), name: name, reason: Self.folderReason(folder: folder, members: members), members: Set(members.map(\.id))))
        }
        return result
    }

    private static func folderReason(folder: String, members: [RepoEntry]) -> GroupingReason {
        let name = (folder as NSString).lastPathComponent
        let owners = Set(members.map { $0.remote?.ownerKey })
        guard owners.count == 1, owners.first! != nil, let remote = members.first?.remote else {
            return .foundTogether(folder: name)
        }
        // ghq: every copy here sits at …/<host>/<owner>/<name> matching its remote.
        let isLayout = members.allSatisfy { entry in
            guard let r = entry.remote else { return false }
            return entry.copies.contains { copy in
                let parts = copy.url.pathComponents.suffix(3).map { $0.lowercased() }
                return parts == [r.host, r.owner.lowercased(), r.name.lowercased()]
            }
        }
        return isLayout ? .hostOwnerLayout(host: remote.host, owner: remote.owner) : .sameOwnerInFolder(host: remote.host, owner: remote.owner, folder: name)
    }

    func isContainer(_ folder: String, members: [RepoEntry], rootPaths: Set<String>) -> Bool {
        if rootPaths.contains(folder) { return true }
        if let home = homeDirectory.map({ normalizedPath($0.path) }) {
            if folder == home || (folder as NSString).deletingLastPathComponent == home { return true }
        }
        if containerFolderNames.contains((folder as NSString).lastPathComponent.lowercased()) { return true }
        if members.count > largeFolderLimit {
            let stems = members.compactMap { Self.stem(of: $0.remote?.name ?? $0.name)?.key }
            let largest = Dictionary(grouping: stems, by: { $0 }).values.map(\.count).max() ?? 0
            return largest * 2 <= members.count
        }
        return false
    }

    /// First word of a repo name — `harbor` in `harbor-app`, `Tide` in `TideAdmin` —
    /// split at punctuation and lower→upper case changes. Shorter than 3 letters is noise.
    static func stem(of name: String) -> (key: String, display: String)? {
        var word = ""
        var previous: Character?
        for char in name {
            if !(char.isLetter || char.isNumber) { if word.isEmpty { continue } else { break } }
            if let p = previous, p.isLowercase, char.isUppercase { break }
            word.append(char)
            previous = char
        }
        guard word.count >= 3 else { return nil }
        return (word.lowercased(), word)
    }

    // MARK: - Name variants (leftovers only)

    /// Names shorter than this (letters and digits) are too generic to group by:
    /// `frontend`, `dotfiles` and `homepage` are 8.
    static let variantMinimumLength = 9

    /// Among repos no other rule placed: names that are variants of one another group,
    /// whoever owns them — `ChartScope-Screener` / `ChartScope.Screener`, `Lighthouse` /
    /// `Lighthouse-dev`, `Storefront` / `StorefrontV2`. Safe because it only
    /// sees leftovers (it never pulls a repo out of a project) and only joins names where
    /// one is the whole other one, ignoring case and punctuation, optionally followed by a
    /// new word (`-dev`, `V2`, ` Kopie`) — never two names that merely start alike
    /// (`harbor-app` / `harbor-admin`), so a big account's repos can't chain together.
    static func variantProjects(_ leftovers: [RepoEntry], notRelated: Set<RepoPair>) -> [Project] {
        let keyed = leftovers.map { (entry: $0, key: normalizedName($0.name)) }
            .filter { $0.key.count >= variantMinimumLength }
            .sorted { ($0.key.count, $0.entry.id) < ($1.key.count, $1.entry.id) }
        var sets = DisjointSets(keyed.map(\.entry.id), notRelated: notRelated)
        for (i, short) in keyed.enumerated() {
            for long in keyed[(i + 1)...] where isVariant(long.entry.name, of: short.key) {
                sets.union(short.entry.id, long.entry.id)
            }
        }
        var seen: Set<RepoID> = []
        var projects: [Project] = []
        for item in keyed where !seen.contains(item.entry.id) {
            let members = sets.members(of: item.entry.id)
            seen.formUnion(members)
            guard members.count >= 2 else { continue }
            // Named after the shortest member (the first in `keyed` order): the base name.
            let repos = keyed.filter { members.contains($0.entry.id) }.map(\.entry)
            let name = repos[0].name
            projects.append(Project(
                id: ProjectID("name:\(normalizedName(name))"),
                name: name,
                reasons: [.nameVariants(name: name)],
                repos: sortedRepos(repos)
            ))
        }
        return projects
    }

    /// Letters and digits only, lowercased: `ChartScope.Screener` → `chartscopescreener`.
    static func normalizedName(_ name: String) -> String {
        name.filter { $0.isLetter || $0.isNumber }.lowercased()
    }

    /// Whether `name` normalizes to `key`, or to `key` followed by a new word: the next
    /// character after the matched part is punctuation, a space, a digit, or an upper-case
    /// letter after a lower-case one.
    static func isVariant(_ name: String, of key: String) -> Bool {
        let chars = Array(name)
        var remaining = key[...]
        var index = 0
        while !remaining.isEmpty, index < chars.count {
            let char = chars[index]
            if char.isLetter || char.isNumber {
                let lower = char.lowercased()
                guard remaining.hasPrefix(lower) else { return false }
                remaining = remaining.dropFirst(lower.count)
            }
            index += 1
        }
        guard remaining.isEmpty else { return false }
        guard index < chars.count else { return true }
        let next = chars[index]
        return !next.isLetter || (next.isUppercase && chars[index - 1].isLowercase)
    }

    // MARK: - Ordering

    static func sortedRepos(_ repos: [RepoEntry]) -> [RepoEntry] {
        repos.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    static func sortedProjects(_ projects: [Project]) -> [Project] {
        projects.sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }
}

/// Union-find over repo ids that refuses merges which would put a "not related" pair
/// in the same set.
private struct DisjointSets {
    private var parent: [RepoID: RepoID] = [:]
    private var sets: [RepoID: Set<RepoID>] = [:]
    private let notRelated: [RepoID: Set<RepoID>]

    init(_ ids: [RepoID], notRelated: Set<RepoPair>) {
        for id in ids {
            parent[id] = id
            sets[id] = [id]
        }
        var map: [RepoID: Set<RepoID>] = [:]
        for pair in notRelated {
            map[pair.first, default: []].insert(pair.second)
            map[pair.second, default: []].insert(pair.first)
        }
        self.notRelated = map
    }

    mutating func find(_ id: RepoID) -> RepoID {
        guard let p = parent[id], p != id else { return id }
        let root = find(p)
        parent[id] = root
        return root
    }

    mutating func size(of id: RepoID) -> Int { sets[find(id)]?.count ?? 1 }

    mutating func members(of id: RepoID) -> Set<RepoID> { sets[find(id)] ?? [id] }

    mutating func union(_ a: RepoID, _ b: RepoID) {
        let ra = find(a), rb = find(b)
        guard ra != rb, let sa = sets[ra], let sb = sets[rb] else { return }
        guard !sa.contains(where: { !(notRelated[$0] ?? []).isDisjoint(with: sb) }) else { return }
        let (big, small) = sa.count >= sb.count ? (ra, rb) : (rb, ra)
        parent[small] = big
        sets[big]!.formUnion(sets[small]!)
        sets[small] = nil
    }
}
