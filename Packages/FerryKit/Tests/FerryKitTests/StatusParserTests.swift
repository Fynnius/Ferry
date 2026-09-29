import Foundation
import Testing
@testable import FerryKit

@Suite("Porcelain v2 parser")
struct StatusParserTests {
    private func parse(_ records: [String]) -> RepoStatus {
        StatusParser.parse(Data((records.joined(separator: "\0") + "\0").utf8))
    }

    @Test func branchHeadersWithUpstream() {
        let status = parse([
            "# branch.oid 1234567890abcdef1234567890abcdef12345678",
            "# branch.head feature/login",
            "# branch.upstream origin/feature/login",
            "# branch.ab +3 -2",
            "# stash 4",
        ])
        #expect(status.branch.head == "feature/login")
        #expect(status.branch.upstream == "origin/feature/login")
        #expect(status.branch.ahead == 3)
        #expect(status.branch.behind == 2)
        #expect(status.branch.upstreamGone == false)
        #expect(status.stashCount == 4)
        #expect(status.syncState == .diverged(ahead: 3, behind: 2))
        #expect(!status.hasChanges)
    }

    @Test func initialRepoAndDetachedHead() {
        let initial = parse(["# branch.oid (initial)", "# branch.head main"])
        #expect(initial.branch.oid == nil)
        #expect(!initial.branch.hasCommits)

        let detached = parse(["# branch.oid abcdef0123456789abcdef0123456789abcdef01", "# branch.head (detached)"])
        #expect(detached.branch.isDetached)
        #expect(detached.branch.oid?.hasPrefix("abcdef") == true)
    }

    @Test func upstreamWithoutAheadBehindIsGone() {
        let status = parse([
            "# branch.oid abcdef0123456789abcdef0123456789abcdef01",
            "# branch.head topic",
            "# branch.upstream origin/topic",
        ])
        #expect(status.branch.upstreamGone)
        #expect(status.syncState == .upstreamGone)
    }

    @Test func ordinaryEntriesSplitIntoStagedAndUnstaged() {
        let hash = String(repeating: "a", count: 40)
        let status = parse([
            "# branch.oid \(hash)",
            "# branch.head main",
            "1 M. N... 100644 100644 100644 \(hash) \(hash) staged.swift",
            "1 .M N... 100644 100644 100644 \(hash) \(hash) dir with spaces/unstaged file.txt",
            "1 MM N... 100644 100644 100644 \(hash) \(hash) both.md",
            "1 A. N... 000000 100644 100644 \(hash) \(hash) new.txt",
            "1 .D N... 100644 100644 000000 \(hash) \(hash) gone.txt",
            "? café/über.txt",
        ])
        #expect(status.staged.map(\.path) == ["staged.swift", "both.md", "new.txt"])
        #expect(status.staged.map(\.kind) == [.modified, .modified, .added])
        #expect(status.unstaged.map(\.path) == ["dir with spaces/unstaged file.txt", "both.md", "gone.txt"])
        #expect(status.unstaged.last?.kind == .deleted)
        #expect(status.untracked.map(\.path) == ["café/über.txt"])
        #expect(status.changedPathCount == 6)
        #expect(status.unstaged[0].fileName == "unstaged file.txt")
        #expect(status.unstaged[0].directory == "dir with spaces")
    }

    @Test func renameRecordReadsNewThenOriginalPath() {
        let hash = String(repeating: "b", count: 40)
        let status = parse([
            "# branch.oid \(hash)",
            "# branch.head main",
            "2 R. N... 100644 100644 100644 \(hash) \(hash) R100 new name.swift",
            "old name.swift",
            "? after.txt",
        ])
        #expect(status.staged.count == 1)
        #expect(status.staged[0].kind == .renamed)
        #expect(status.staged[0].path == "new name.swift")
        #expect(status.staged[0].originalPath == "old name.swift")
        #expect(status.untracked.map(\.path) == ["after.txt"])
    }

    @Test func unmergedAndSubmoduleEntries() {
        let hash = String(repeating: "c", count: 40)
        let status = parse([
            "# branch.oid \(hash)",
            "# branch.head main",
            "u UU N... 100644 100644 100644 100644 \(hash) \(hash) \(hash) conflict.txt",
            "1 .M SC.. 160000 160000 160000 \(hash) \(hash) vendor/lib",
        ])
        #expect(status.conflicted.map(\.path) == ["conflict.txt"])
        #expect(status.unstaged.first?.isSubmodule == true)
        #expect(PrimaryAction(status: status) == .none)
    }

    @Test func emptyInputIsClean() {
        let status = StatusParser.parse(Data())
        #expect(!status.hasChanges)
        #expect(status.branch.head == nil)
    }
}

@Suite("Primary action state machine")
struct PrimaryActionTests {
    private let hash = String(repeating: "d", count: 40)

    private func status(staged: Bool = false, unstaged: Bool = false, upstream: String? = "origin/main", ahead: Int = 0, behind: Int = 0, hasRemote: Bool = true, oid: String? = "x") -> RepoStatus {
        RepoStatus(
            branch: BranchState(head: "main", oid: oid, upstream: upstream, ahead: ahead, behind: behind),
            staged: staged ? [FileChange(path: "a", kind: .modified, area: .staged)] : [],
            unstaged: unstaged ? [FileChange(path: "b", kind: .modified, area: .unstaged)] : [],
            hasRemote: hasRemote
        )
    }

    @Test func commitLabelFollowsStaging() {
        #expect(PrimaryAction(status: status(staged: true, unstaged: true)) == .commit(all: false))
        #expect(PrimaryAction(status: status(unstaged: true)) == .commit(all: true))
    }

    @Test func cleanRepoStates() {
        #expect(PrimaryAction(status: status()) == .none)
        #expect(PrimaryAction(status: status(ahead: 2)) == .sync(ahead: 2, behind: 0))
        #expect(PrimaryAction(status: status(behind: 3)) == .sync(ahead: 0, behind: 3))
        #expect(PrimaryAction(status: status(ahead: 1, behind: 1)) == .sync(ahead: 1, behind: 1))
        #expect(PrimaryAction(status: status(upstream: nil)) == .publish)
        #expect(PrimaryAction(status: status(upstream: nil, hasRemote: false)) == .none)
        #expect(PrimaryAction(status: status(upstream: nil, oid: nil)) == .none)
    }

    @Test func attention() {
        #expect(!status().needsAttention)
        #expect(status(unstaged: true).needsAttention)
        #expect(status(behind: 1).needsAttention)
        #expect(status(upstream: nil).needsAttention)
        #expect(!status(upstream: nil, hasRemote: false).needsAttention)
    }
}

@Suite("Status fingerprint")
struct StatusFingerprintTests {
    private func status(_ files: [FileChange], ahead: Int = 0) -> RepoStatus {
        RepoStatus(branch: BranchState(head: "main", oid: "abc", upstream: "origin/main", ahead: ahead), unstaged: files)
    }

    @Test func stableForEqualStatusAndChangesWithAnyDifference() {
        let a = FileChange(path: "a.txt", kind: .modified, area: .unstaged)
        let b = FileChange(path: "b.txt", kind: .modified, area: .unstaged)
        #expect(status([a, b]).fingerprint == status([b, a]).fingerprint, "order doesn't matter")
        #expect(status([a]).fingerprint != status([a, b]).fingerprint)
        #expect(status([a]).fingerprint != status([a], ahead: 1).fingerprint)
        #expect(status([FileChange(path: "a.txt", kind: .deleted, area: .unstaged)]).fingerprint != status([a]).fingerprint)
        #expect(status([a]).fingerprint.count == 64)
    }

    @Test func overridesDecodeWithoutSnoozeKey() throws {
        let old = #"{"pinned":[],"hidden":[]}"#
        let decoded = try JSONDecoder().decode(DiscoveryOverrides.self, from: Data(old.utf8))
        #expect(decoded.snoozed.isEmpty)
        var overrides = DiscoveryOverrides()
        overrides.snoozed["/r"] = "f"
        let roundTrip = try JSONDecoder().decode(DiscoveryOverrides.self, from: JSONEncoder().encode(overrides))
        #expect(roundTrip.snoozed == ["/r": "f"])
    }
}
