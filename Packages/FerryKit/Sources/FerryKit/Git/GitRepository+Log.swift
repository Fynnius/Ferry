import Foundation

public struct Commit: Hashable, Sendable, Identifiable {
    public var id: String
    public var parents: [String]
    /// Decorations, e.g. `HEAD -> main`, `origin/main`, `tag: v1.0`.
    public var refs: [String]
    public var author: String
    public var email: String
    public var date: Date
    public var subject: String

    public var shortID: String { String(id.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
}

extension GitRepository {
    /// A page of history for the graph, newest first: parents always after their children,
    /// otherwise by commit date. By default the current branch plus its upstream, like VS
    /// Code's graph; `allBranches` shows every ref.
    ///
    /// Date order, not `--topo-order`: topo order lists each line of history as one block,
    /// so a mainline that merges a long-lived branch again and again (a `staging` → `main`
    /// PR staircase) prints every merge before any of the branch's commits, and each merge
    /// holds its own lane open down to its commit — 50 merges, 50 lanes. Date order
    /// interleaves the two lines as they happened and draws them in two or three lanes.
    public func log(limit: Int = 200, skip: Int = 0, allBranches: Bool = false) async throws -> [Commit] {
        guard try await hasCommits() else { return [] }
        var args = ["log", "-z", "--date-order", "--format=%H%x1f%P%x1f%D%x1f%an%x1f%ae%x1f%at%x1f%s", "--max-count=\(limit)", "--skip=\(skip)"]
        if allBranches {
            args.append("--all")
        } else {
            args.append("HEAD")
            let upstream = try await runner.runAllowingFailure(["rev-parse", "-q", "--verify", "@{upstream}"], in: root)
            if upstream.exitCode == 0 { args.append("@{upstream}") }
        }
        args.append("--")
        let output = try await runner.run(args, in: root)
        return output.stdout.split(separator: 0).compactMap { Self.parseCommit(String(decoding: $0, as: UTF8.self)) }
    }

    static func parseCommit(_ record: String) -> Commit? {
        let fields = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 7, !fields[0].isEmpty else { return nil }
        return Commit(
            id: fields[0],
            parents: fields[1].split(separator: " ").map(String.init),
            refs: fields[2].isEmpty ? [] : fields[2].components(separatedBy: ", "),
            author: fields[3],
            email: fields[4],
            date: Date(timeIntervalSince1970: TimeInterval(fields[5]) ?? 0),
            subject: fields[6]
        )
    }

    /// Runs a write through the repo's serial queue. Shared by the extensions.
    func writeGit(_ arguments: [String], stdin: Data? = nil) async throws {
        try await serialWrite { [self] in
            try await runner.run(arguments, in: root, as: .write, stdin: stdin)
        }
    }
}
