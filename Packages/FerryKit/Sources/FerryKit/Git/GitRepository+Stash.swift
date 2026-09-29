import Foundation

public struct Stash: Hashable, Sendable, Identifiable {
    /// Position in the stash list; `stash@{index}`.
    public var index: Int
    public var message: String
    public var date: Date

    public var ref: String { "stash@{\(index)}" }
    public var id: String { "\(index):\(date.timeIntervalSince1970)" }
}

extension GitRepository {
    public func stashes() async throws -> [Stash] {
        let output = try await runner.run(["stash", "list", "-z", "--format=%gd%x1f%ct%x1f%gs"], in: root)
        return output.stdout.split(separator: 0).compactMap { record in
            let fields = String(decoding: record, as: UTF8.self).split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3,
                  let open = fields[0].firstIndex(of: "{"), let close = fields[0].firstIndex(of: "}"),
                  let index = Int(fields[0][fields[0].index(after: open)..<close]) else { return nil }
            return Stash(index: index, message: fields[2], date: Date(timeIntervalSince1970: TimeInterval(fields[1]) ?? 0))
        }
    }

    /// Stashes changes (untracked files included by default). With `paths`, only those.
    public func stash(message: String? = nil, includeUntracked: Bool = true, paths: [String] = []) async throws {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if let message, !message.trimmingCharacters(in: .whitespaces).isEmpty { args += ["-m", message] }
        if !paths.isEmpty { args += ["--"] + paths }
        try await writeGit(args)
    }

    public func applyStash(_ stash: Stash) async throws {
        try await writeGit(["stash", "apply", stash.ref])
    }

    public func popStash(_ stash: Stash) async throws {
        try await writeGit(["stash", "pop", stash.ref])
    }

    public func dropStash(_ stash: Stash) async throws {
        try await writeGit(["stash", "drop", stash.ref])
    }
}
