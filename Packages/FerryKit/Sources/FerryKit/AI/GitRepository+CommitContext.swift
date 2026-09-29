import Foundation

extension GitRepository {
    /// Gathers what the AI commit message is written from, for exactly the files Ferry's
    /// commit button would commit: the staged changes, or — when nothing is staged —
    /// every change including untracked files (Commit All).
    ///
    /// The secret guard runs on paths first: a file that looks like a secret is never
    /// opened or diffed. Lockfiles and generated files are skipped the same way, so a
    /// huge lockfile never costs a diff.
    public func commitContext(rules: CommitPromptRules = .default) async throws -> CommitContext {
        async let subjects = recentSubjects(limit: rules.recentSubjectCount)
        let status = try await status()
        let includesAll = status.staged.isEmpty
        let changes = includesAll ? status.unstaged + status.untracked : status.staged

        var files = changes.map { CommitContext.File(path: $0.path, change: Self.contextChange($0), content: .unavailable) }
        var tracked: [Int] = []
        var untracked: [Int] = []
        for (index, change) in changes.enumerated() {
            if rules.isSecret(change.path) || change.originalPath.map(rules.isSecret) == true {
                files[index].content = .withheldSecret
            } else if let reason = rules.skipReason(for: change.path) {
                files[index].content = .skipped(reason)
            } else if change.kind == .untracked {
                untracked.append(index)
            } else {
                tracked.append(index)
            }
        }

        let diffs = try await trackedDiffs(
            for: tracked.map { changes[$0] },
            cached: !includesAll,
            hasCommits: status.branch.hasCommits
        )
        for index in tracked {
            files[index].content = diffs[changes[index].path] ?? .unavailable
        }
        readUntracked(untracked, into: &files, rules: rules)

        return CommitContext(
            repositoryName: root.lastPathComponent,
            branch: status.branch.head,
            recentSubjects: try await subjects,
            includesAllChanges: includesAll,
            files: files
        )
    }

    // MARK: - Tracked files

    /// Diffs exactly the given paths — never the whole tree, so secret files stay unread.
    /// `git diff` has no `--pathspec-from-file`, so paths go after `--` in batches that
    /// stay far below the kernel's argument limit.
    private func trackedDiffs(for changes: [FileChange], cached: Bool, hasCommits: Bool) async throws -> [String: CommitContext.File.Content] {
        // --no-textconv: textconv drivers can decrypt (git-crypt) or run arbitrary tools.
        let base = ["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "-M"]
            + (cached ? ["--cached"] : hasCommits ? ["HEAD"] : [])
        var result: [String: CommitContext.File.Content] = [:]
        for batch in Self.batches(changes) {
            result.merge(try await diffBatch(batch, base: base)) { _, new in new }
        }
        return result
    }

    /// One `--numstat` and one `--patch` run, split per file. Both use the same options,
    /// so git emits files in the same order; if the counts ever differ (a file↔symlink
    /// change prints two patches) it falls back to one run per file.
    private func diffBatch(_ changes: [FileChange], base: [String]) async throws -> [String: CommitContext.File.Content] {
        let paths = ["--"] + changes.flatMap(Self.pathspecs(for:))
        async let numstatRun = runner.run(base + ["--numstat", "-z"] + paths, in: root)
        async let patchRun = runner.run(base + ["--patch"] + paths, in: root)
        let entries = Self.parseNumstat(try await numstatRun.stdout)
        let chunks = Self.splitPatch(try await patchRun.text)

        var result: [String: CommitContext.File.Content] = [:]
        if entries.count == chunks.count {
            for (entry, chunk) in zip(entries, chunks) {
                result[entry.path] = entry.binary ? .binary : .diff(chunk)
            }
            return result
        }

        let byPath = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return try await withThrowingTaskGroup(of: (String, CommitContext.File.Content).self) { group in
            for entry in entries {
                let specs = ["--"] + (byPath[entry.path].map(Self.pathspecs(for:)) ?? [entry.path])
                group.addTask { [runner, root] in
                    if entry.binary { return (entry.path, .binary) }
                    let output = try await runner.run(base + ["--patch"] + specs, in: root)
                    return (entry.path, .diff(output.text.trimmingCharacters(in: .newlines)))
                }
            }
            for try await (path, content) in group { result[path] = content }
            return result
        }
    }

    /// Groups changes so each batch's paths total at most `maxBytes`; a rename's two
    /// paths stay together so git can still pair them.
    static func batches(_ changes: [FileChange], maxBytes: Int = 128 * 1024) -> [[FileChange]] {
        var batches: [[FileChange]] = []
        var current: [FileChange] = []
        var size = 0
        for change in changes {
            let bytes = pathspecs(for: change).reduce(0) { $0 + $1.utf8.count + 1 }
            if !current.isEmpty, size + bytes > maxBytes {
                batches.append(current)
                current = []
                size = 0
            }
            current.append(change)
            size += bytes
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private static func pathspecs(for change: FileChange) -> [String] {
        [change.path] + (change.originalPath.map { [$0] } ?? [])
    }

    /// Parses `git diff --numstat -z`: `added\tdeleted\tpath\0`, or for a rename
    /// `added\tdeleted\t\0old\0new\0`. Binary files show `-` for both counts.
    static func parseNumstat(_ data: Data) -> [(path: String, binary: Bool)] {
        let records = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var entries: [(path: String, binary: Bool)] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let binary = fields[0] == "-" && fields[1] == "-"
            var path = String(fields[2])
            if path.isEmpty {
                guard index + 1 < records.count else { break }
                path = records[index + 1]
                index += 2
            }
            entries.append((path, binary))
        }
        return entries
    }

    /// Splits patch output at each `diff --git` header. Content lines always start with
    /// a space, `+`, `-` or `\`, so a header can't appear inside a hunk.
    static func splitPatch(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var starts = text.ranges(of: "\ndiff --git ").map { text.index(after: $0.lowerBound) }
        if text.hasPrefix("diff --git ") { starts.insert(text.startIndex, at: 0) }
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : text.endIndex
            var chunk = String(text[start..<end])
            while chunk.hasSuffix("\n") { chunk.removeLast() }
            return chunk
        }
    }

    // MARK: - Untracked files

    /// Reads new files from disk, smallest first, and turns each into an additions-only
    /// diff. Symlinks are not followed: a link could point anywhere, including at a key.
    private func readUntracked(_ indices: [Int], into files: inout [CommitContext.File], rules: CommitPromptRules) {
        let fm = FileManager.default
        var readable: [(index: Int, size: Int)] = []
        for index in indices {
            let path = root.appendingPathComponent(files[index].path).path
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                files[index].content = .unavailable
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if size > rules.untrackedFileSizeLimit {
                files[index].content = .tooLarge(bytes: size)
            } else {
                readable.append((index, size))
            }
        }

        var total = 0
        for (index, size) in readable.sorted(by: { $0.size < $1.size }) {
            guard total + size <= rules.untrackedTotalReadLimit else {
                files[index].content = .notRead
                continue
            }
            total += size
            let url = root.appendingPathComponent(files[index].path)
            guard let data = try? Data(contentsOf: url) else {
                files[index].content = .unavailable
                continue
            }
            files[index].content = Self.untrackedContent(path: files[index].path, data: data)
        }
    }

    /// Git's own heuristic: a NUL byte in the first 8000 bytes means binary.
    static func untrackedContent(path: String, data: Data) -> CommitContext.File.Content {
        if data.prefix(8000).contains(0) { return .binary }
        guard let text = String(validating: data, as: UTF8.self) else { return .binary }
        return .diff(additionDiff(path: path, text: text))
    }

    /// What `git diff` would print had the file been added with `git add`.
    static func additionDiff(path: String, text: String) -> String {
        var header = "diff --git a/\(path) b/\(path)\nnew file mode 100644"
        guard !text.isEmpty else { return header }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        header += "\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1\(lines.count == 1 ? "" : ",\(lines.count)") @@"
        var diff = header + "\n" + lines.map { "+" + $0 }.joined(separator: "\n")
        if !endsWithNewline { diff += "\n\\ No newline at end of file" }
        return diff
    }

    static func contextChange(_ change: FileChange) -> CommitContext.File.Change {
        switch change.kind {
        case .added, .untracked: .added
        case .deleted: .deleted
        case .renamed: .renamed(from: change.originalPath ?? change.path)
        case .copied: .copied(from: change.originalPath ?? change.path)
        case .typeChanged: .typeChanged
        case .modified, .conflicted: .modified
        }
    }
}
