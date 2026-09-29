import Foundation

/// Parses `git status --porcelain=v2 -z --branch --show-stash`.
/// With `-z` paths are raw bytes, NUL-terminated, never quoted; renames print `new\0old`.
public enum StatusParser {
    public static func parse(_ data: Data) -> RepoStatus {
        var branch = BranchState(head: nil, oid: nil)
        var sawAheadBehind = false
        var staged: [FileChange] = []
        var unstaged: [FileChange] = []
        var untracked: [FileChange] = []
        var conflicted: [FileChange] = []
        var stashCount = 0

        let records = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let type = record.first else { continue }

            switch type {
            case "#":
                let fields = record.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard fields.count == 2 else { continue }
                let value = fields[1]
                switch fields[0] {
                case "branch.oid": branch.oid = value == "(initial)" ? nil : value
                case "branch.head": branch.head = value == "(detached)" ? nil : value
                case "branch.upstream": branch.upstream = value
                case "branch.ab":
                    sawAheadBehind = true
                    let parts = value.split(separator: " ")
                    if parts.count == 2 {
                        branch.ahead = Int(parts[0].dropFirst()) ?? 0
                        branch.behind = Int(parts[1].dropFirst()) ?? 0
                    }
                case "stash": stashCount = Int(value) ?? 0
                default: break
                }

            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                let xy = Array(fields[1])
                let isSubmodule = fields[2].first == "S"
                let path = String(fields[8])
                if let kind = kind(for: xy[0]) {
                    staged.append(FileChange(path: path, kind: kind, area: .staged, isSubmodule: isSubmodule))
                }
                if let kind = kind(for: xy[1]) {
                    unstaged.append(FileChange(path: path, kind: kind, area: .unstaged, isSubmodule: isSubmodule))
                }

            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10 else { continue }
                let xy = Array(fields[1])
                let isSubmodule = fields[2].first == "S"
                let path = String(fields[9])
                let original = index < records.count ? records[index] : nil
                index += 1
                if let kind = kind(for: xy[0]) {
                    staged.append(FileChange(path: path, originalPath: original, kind: kind, area: .staged, isSubmodule: isSubmodule))
                }
                if let kind = kind(for: xy[1]) {
                    unstaged.append(FileChange(path: path, kind: kind, area: .unstaged, isSubmodule: isSubmodule))
                }

            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                conflicted.append(FileChange(path: String(fields[10]), kind: .conflicted, area: .conflicted, isSubmodule: fields[2].first == "S"))

            case "?":
                let path = String(record.dropFirst(2))
                untracked.append(FileChange(path: path, kind: .untracked, area: .untracked))

            default:
                continue
            }
        }

        // An upstream without an ahead/behind line means its remote ref is gone.
        if branch.upstream != nil && !sawAheadBehind {
            branch.upstreamGone = true
        }

        return RepoStatus(
            branch: branch,
            staged: staged,
            unstaged: unstaged,
            untracked: untracked,
            conflicted: conflicted,
            stashCount: stashCount
        )
    }

    private static func kind(for code: Character) -> FileChange.Kind? {
        switch code {
        case "M": .modified
        case "T": .typeChanged
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "U": .conflicted
        default: nil
        }
    }
}
