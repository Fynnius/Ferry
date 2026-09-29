import Foundation

/// A local or remote-tracking branch.
public struct Branch: Hashable, Sendable, Identifiable {
    /// Full ref, e.g. `refs/heads/main` or `refs/remotes/origin/main`.
    public var ref: String
    /// Short name, e.g. `main` or `origin/main`.
    public var name: String
    public var isRemote: Bool
    public var isCurrent: Bool
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var upstreamGone: Bool
    public var lastCommitDate: Date?
    public var lastCommitSubject: String

    public var id: String { ref }

    /// For a remote branch, its name without the remote: `origin/feature/x` → `feature/x`.
    public var nameWithoutRemote: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

extension GitRepository {
    /// Local branches first (current first, then most recently committed), then remote ones.
    public func branches() async throws -> [Branch] {
        let format = ["%(refname)", "%(refname:short)", "%(upstream:short)", "%(upstream:track,nobracket)", "%(HEAD)", "%(committerdate:unix)", "%(subject)"]
            .joined(separator: "%1f")
        let output = try await runner.run(["for-each-ref", "--format=\(format)", "refs/heads", "refs/remotes"], in: root)
        let branches = output.text.split(separator: "\n").compactMap { Self.parseBranch(String($0)) }
        return branches.sorted { a, b in
            if a.isRemote != b.isRemote { return !a.isRemote }
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            return (a.lastCommitDate ?? .distantPast) > (b.lastCommitDate ?? .distantPast)
        }
    }

    static func parseBranch(_ line: String) -> Branch? {
        let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 7 else { return nil }
        let ref = fields[0]
        // `refs/remotes/origin/HEAD` is a pointer, not a branch.
        if ref.hasPrefix("refs/remotes/") && ref.hasSuffix("/HEAD") { return nil }
        let track = fields[3]
        return Branch(
            ref: ref,
            name: fields[1],
            isRemote: ref.hasPrefix("refs/remotes/"),
            isCurrent: fields[4] == "*",
            upstream: fields[2].isEmpty ? nil : fields[2],
            ahead: Self.trackCount("ahead", in: track),
            behind: Self.trackCount("behind", in: track),
            upstreamGone: track == "gone",
            lastCommitDate: TimeInterval(fields[5]).map(Date.init(timeIntervalSince1970:)),
            lastCommitSubject: fields[6...].joined(separator: "\u{1f}")
        )
    }

    private static func trackCount(_ word: String, in track: String) -> Int {
        guard let range = track.range(of: #"\#(word) (\d+)"#, options: .regularExpression) else { return 0 }
        return Int(track[range].split(separator: " ").last ?? "") ?? 0
    }

    /// True when `name` is a valid new branch name (`git check-ref-format --branch`).
    public func isValidBranchName(_ name: String) async -> Bool {
        guard !name.isEmpty, !name.contains(" ") else { return false }
        let output = try? await runner.runAllowingFailure(["check-ref-format", "--branch", name], in: root)
        return output?.exitCode == 0
    }

    /// Switches to a branch. A remote branch checks out its local counterpart, creating
    /// a tracking branch when none exists yet.
    public func switchTo(_ branch: Branch) async throws {
        if branch.isRemote {
            let local = branch.nameWithoutRemote
            let exists = try await runner.runAllowingFailure(["rev-parse", "-q", "--verify", "refs/heads/\(local)"], in: root).exitCode == 0
            if exists {
                try await writeGit(["switch", local])
            } else {
                try await writeGit(["switch", "-c", local, "--track", branch.name])
            }
        } else {
            try await writeGit(["switch", branch.name])
        }
    }

    /// Creates a branch from `start` (default: HEAD) and optionally switches to it.
    public func createBranch(_ name: String, from start: String? = nil, switchTo: Bool = true) async throws {
        var args = switchTo ? ["switch", "-c", name] : ["branch", name]
        if let start { args.append(start) }
        try await writeGit(args)
    }

    public func renameBranch(_ old: String, to new: String) async throws {
        try await writeGit(["branch", "-m", old, new])
    }

    /// Deletes a local branch. Without `force`, git refuses unmerged branches and this
    /// throws `.branchNotFullyMerged` so the UI can ask before forcing.
    public func deleteBranch(_ name: String, force: Bool = false) async throws {
        try await writeGit(["branch", force ? "-D" : "-d", name])
    }
}
