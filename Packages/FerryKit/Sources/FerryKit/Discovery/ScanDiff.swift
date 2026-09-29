import Foundation

/// What changed between two scans, for the UI to announce new repos subtly and
/// let vanished ones disappear quietly. Only working repos count; worktrees and
/// submodules come and go with their parent.
public struct ScanDiff: Hashable, Sendable {
    public struct Move: Hashable, Sendable {
        public var id: RepoID
        public var from: URL
        public var to: URL
    }

    /// Repos never seen before — worth a quiet "New: harbor-api".
    public var newRepos: [DiscoveredRepo]
    /// A new clone of a repo that was already known: a duplicate, not a new repo.
    public var newCopies: [DiscoveredRepo]
    /// Same remote, old folder gone, new folder appeared.
    public var moved: [Move]
    /// Gone from disk. Repos under a root that couldn't be read this time (unplugged
    /// drive) are left out: they're unavailable, not removed.
    public var removed: [DiscoveredRepo]
    /// Every repo with more than one copy after this scan.
    public var duplicates: [RepoID: [URL]]

    public var isEmpty: Bool { newRepos.isEmpty && newCopies.isEmpty && moved.isEmpty && removed.isEmpty }

    /// - Parameter old: the previous scan; nil on first launch, where nothing is "new".
    public init(from old: ScanResult?, to new: ScanResult) {
        let newRepos = Self.working(new)
        let newByID = Dictionary(grouping: newRepos, by: Self.id)
        duplicates = newByID.filter { $0.value.count > 1 }.mapValues { $0.map(\.url).sorted { $0.path < $1.path } }

        guard let old else {
            self.newRepos = []
            newCopies = []
            moved = []
            removed = []
            return
        }
        let oldByID = Dictionary(grouping: Self.working(old), by: Self.id)
        let unavailableRoots = new.unreadableRoots.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }

        var added: [DiscoveredRepo] = []
        var copies: [DiscoveredRepo] = []
        var moves: [Move] = []
        var gone: [DiscoveredRepo] = []
        for id in Set(oldByID.keys).union(newByID.keys).sorted() {
            let before = oldByID[id] ?? [], after = newByID[id] ?? []
            let beforePaths = Set(before.map(\.path)), afterPaths = Set(after.map(\.path))
            var appeared = after.filter { !beforePaths.contains($0.path) }.sorted { $0.path < $1.path }
            var vanished = before.filter { !afterPaths.contains($0.path) }.sorted { $0.path < $1.path }
            // A partial scan proves nothing about what's missing.
            if new.wasCancelled { vanished = [] }
            vanished.removeAll { repo in unavailableRoots.contains { repo.path.hasPrefix($0) } }

            while !appeared.isEmpty, !vanished.isEmpty {
                moves.append(Move(id: id, from: vanished.removeFirst().url, to: appeared.removeFirst().url))
            }
            if before.isEmpty, let first = appeared.first {
                added.append(first)
                appeared.removeFirst()
            }
            copies += appeared
            gone += vanished
        }
        self.newRepos = added
        newCopies = copies
        moved = moves
        removed = gone
    }

    private static func working(_ scan: ScanResult) -> [DiscoveredRepo] {
        scan.repos.filter { $0.kind == .repository }
    }

    private static func id(_ repo: DiscoveredRepo) -> RepoID {
        RepoID(remote: repo.remote, path: repo.path)
    }
}
