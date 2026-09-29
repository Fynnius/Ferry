import Foundation

/// The two messages sent to the model.
public struct CommitPrompt: Sendable, Equatable {
    public var system: String
    public var user: String

    public init(system: String, user: String) {
        self.system = system
        self.user = user
    }
}

/// Turns a `CommitContext` into the system and user messages. Pure: no git,
/// no disk, no network — every packing decision is testable from a hand-built context.
public struct CommitPromptBuilder: Sendable {
    public var rules: CommitPromptRules

    public init(rules: CommitPromptRules = .default) {
        self.rules = rules
    }

    public func build(from context: CommitContext) -> CommitPrompt {
        let packed = pack(context.files)
        let conventional = Self.usesConventionalCommits(context.recentSubjects, threshold: rules.conventionalCommitThreshold)
        return CommitPrompt(system: Self.systemPrompt(conventional: conventional), user: userPrompt(context, packed: packed))
    }

    // MARK: - Packing

    /// How one file ends up in the prompt.
    enum Placement: Equatable {
        case included
        case truncated
        case overBudget
        /// Path looks like a secret: named, nothing else.
        case secret
        /// Listed with a note, never diffed.
        case listed(String)
    }

    struct Packed: Equatable {
        /// Per file, same order as the context.
        var placements: [Placement]
        /// Diff pieces in packing order (smallest first).
        var diffs: [String]
    }

    static let truncationMarker = "... [diff truncated]"

    /// Fills the diff budget smallest-first, so a commit with five small files and one huge
    /// one describes all six instead of just the huge one. Each file is capped at
    /// `perFileLimit`; files that no longer fit are listed by name.
    func pack(_ files: [CommitContext.File]) -> Packed {
        var placements = [Placement](repeating: .overBudget, count: files.count)
        var candidates: [(index: Int, diff: String, length: Int)] = []

        for (index, file) in files.enumerated() {
            // Re-checked here so a secret can't reach the prompt even if a caller built
            // the context by hand.
            if file.content == .withheldSecret || rules.isSecret(file.path) || file.change.originalPath.map(rules.isSecret) == true {
                placements[index] = .secret
                continue
            }
            if let reason = rules.skipReason(for: file.path) {
                placements[index] = .listed(Self.note(for: .skipped(reason)))
                continue
            }
            if case .diff(let diff) = file.content {
                candidates.append((index, diff, diff.count))
            } else {
                placements[index] = .listed(Self.note(for: file.content))
            }
        }

        var remaining = rules.diffBudget
        var diffs: [String] = []
        for candidate in candidates.sorted(by: { ($0.length, $0.index) < ($1.length, $1.index) }) {
            var piece = candidate.diff
            var truncated = false
            if candidate.length > rules.perFileLimit {
                piece = Self.truncate(piece, to: rules.perFileLimit)
                truncated = true
            }
            guard piece.count <= remaining else { continue }
            remaining -= piece.count
            diffs.append(piece)
            placements[candidate.index] = truncated ? .truncated : .included
        }
        return Packed(placements: placements, diffs: diffs)
    }

    /// Cuts at the last full line within `limit` and appends the marker.
    static func truncate(_ diff: String, to limit: Int) -> String {
        var head = diff.prefix(limit)
        if let newline = head.lastIndex(of: "\n") {
            head = head[...newline]
        } else {
            head += "\n"
        }
        return head + truncationMarker
    }

    static func note(for content: CommitContext.File.Content) -> String {
        switch content {
        case .withheldSecret: "SKIPPED: looks like a secret file"
        case .binary: "binary file, diff omitted"
        case .skipped(.lockfile): "lockfile, diff omitted"
        case .skipped(.generated): "generated file, diff omitted"
        case .tooLarge(let bytes): "new file too large (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))), diff omitted"
        case .notRead: "diff omitted — over size budget"
        case .unavailable, .diff: "diff unavailable"
        }
    }

    // MARK: - Messages

    static func systemPrompt(conventional: Bool) -> String {
        var rules = """
        You are an assistant that writes git commit messages for a software developer, based on their staged changes.

        Rules:
        - Write ONLY the commit message text. No preamble, no explanation, no markdown code fences, no quotes around the message.
        - First line is the subject: a concise, imperative-mood summary, at most 72 characters, no trailing period.
        - If the change needs more explanation, add one blank line after the subject, then a short body (plain text, wrapped, a few bullet points or sentences — never more than necessary).
        - Match the style of the RECENT COMMITS shown below: if they use a conventional-commit prefix (feat:, fix:, chore:, refactor:, docs:, test:, etc.), use the correct type for this change and follow the same prefix/scope format. If they don't use a convention, write plain, natural commit messages in the same tone and level of detail.
        - Write in the same language as the RECENT COMMITS (if they are not in English, respond in that language).
        - Base the message only on the actual diff content. Do not invent rationale, ticket numbers, or details not visible in the changes.
        - If a file is marked "diff omitted" or its diff ends with "[diff truncated]", do not describe the missing contents — refer to it only by filename if relevant.
        """
        if conventional {
            rules += "\n- The RECENT COMMITS follow Conventional Commits: start the subject with the type that fits this change (feat, fix, refactor, docs, test, chore, …), using the same scope format they use."
        }
        return rules
    }

    func userPrompt(_ context: CommitContext, packed: Packed) -> String {
        let subjects = context.recentSubjects.isEmpty
            ? "(none yet — this is the first commit)"
            : context.recentSubjects.map { "- \($0)" }.joined(separator: "\n")

        var lines: [String] = []
        for (file, placement) in zip(context.files, packed.placements) {
            let change = Self.describe(file.change)
            switch placement {
            case .included: lines.append("- \(file.path) (\(change))")
            case .truncated: lines.append("- \(file.path) (\(change); diff truncated)")
            case .overBudget: lines.append("- \(file.path) (\(change); diff omitted — over size budget)")
            case .secret: lines.append("- \(file.path) (SKIPPED: looks like a secret file)")
            case .listed(let note): lines.append("- \(file.path) (\(change); \(note))")
            }
        }
        if lines.count > rules.maxListedFiles {
            let hidden = lines.count - rules.maxListedFiles
            lines = Array(lines.prefix(rules.maxListedFiles)) + ["- … and \(hidden) more files"]
        }

        let diff = packed.diffs.isEmpty ? "(no text diff available — see the file list)" : packed.diffs.joined(separator: "\n\n")
        return """
        Repository: \(context.repositoryName)
        Branch: \(context.branch ?? "(detached HEAD)")

        Recent commit subjects (for style reference only — do not copy their content):
        \(subjects)

        Changed files:
        \(lines.joined(separator: "\n"))

        Diff:
        \(diff)

        Write the commit message now.
        """
    }

    static func describe(_ change: CommitContext.File.Change) -> String {
        switch change {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        case .typeChanged: "type changed"
        case .renamed(let from): "renamed from \(from)"
        case .copied(let from): "copied from \(from)"
        }
    }

    // MARK: - Style

    /// True when at least `threshold` of the subjects look like `type(scope): subject`.
    public static func usesConventionalCommits(_ subjects: [String], threshold: Double = 0.7) -> Bool {
        guard !subjects.isEmpty else { return false }
        let pattern = /^(feat|fix|chore|refactor|docs|test|tests|style|perf|build|ci|revert)(\([^)]*\))?!?: \S/.ignoresCase()
        let matching = subjects.filter { $0.firstMatch(of: pattern) != nil }.count
        return Double(matching) / Double(subjects.count) >= threshold
    }
}

extension CommitContext.File.Change {
    var originalPath: String? {
        switch self {
        case .renamed(let from), .copied(let from): from
        default: nil
        }
    }
}
