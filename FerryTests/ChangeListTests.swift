import Foundation
import SwiftUI
import Testing
@testable import Ferry
import FerryKit

@MainActor
@Suite("Big change lists")
struct ChangeListTests {
    private func lines(_ status: RepoStatus, folded: Set<ChangeSection.Kind> = [], open: Set<String> = []) -> [ChangeLines.Line] {
        ChangeLines.build(ChangeSection.sections(of: status), folded: folded) { section, folder, count in
            open.contains(folder) || ChangeLines.opensByDefault(count)
        }
    }

    @Test func aWholeSubprojectFoldsIntoOneRow() {
        let big = SnapshotFleet.bigRepo(staged: 1598, unstaged: 4, editedAgain: 0)
        let result = lines(big.status!)
        // Staged: header + 1 folder ("storefront-landing/src" and "…/public" share
        // the landing folder, so they split below it). Not Staged: header + 4 files.
        let folders = result.compactMap { line -> (String, Int)? in
            if case .folder(_, let folder, let files) = line.kind { (folder, files.count) } else { nil }
        }
        #expect(folders.map(\.0) == ["storefront-landing/public", "storefront-landing/src"])
        #expect(folders.map(\.1).reduce(0, +) == 1598)
        #expect(result.count == 2 + folders.count + 4, "big folders start folded")
    }

    @Test func foldersSplitBelowTheSharedDirectoryAndSingleFilesStayLoose() {
        let files = ["src/a/1.swift", "src/a/2.swift", "src/b/3.swift", "src/b/4.swift", "src/c/5.swift", "src/root.swift"]
            .map { FileChange(path: $0, kind: .modified, area: .unstaged) }
        let (folders, loose) = ChangeLines.folders(of: files)
        #expect(folders.map(\.0) == ["src/a", "src/b"])
        #expect(loose.map(\.path) == ["src/c/5.swift", "src/root.swift"])
        #expect(ChangeLines.relativeDirectory(of: files[0], in: "src") == "a")
        #expect(ChangeLines.relativeDirectory(of: files[0], in: "src/a") == "")
    }

    @Test func smallGroupsStayFlat() {
        let status = RepoStatus(branch: BranchState(head: "main", oid: "x"), unstaged: (0..<30).map {
            FileChange(path: "dir\($0 % 3)/f\($0).txt", kind: .modified, area: .unstaged)
        })
        let result = lines(status)
        #expect(result.count == 31)
        #expect(!result.contains { if case .folder = $0.kind { true } else { false } })
    }

    @Test func foldedGroupsShowOnlyTheirHeader() {
        let big = SnapshotFleet.bigRepo(staged: 10, unstaged: 5, editedAgain: 0)
        #expect(lines(big.status!, folded: [.staged]).count == 1 + 1 + 5)
    }

    @Test func anOpenedHugeFolderListsTheFirstRowsAndCountsTheRest() {
        let files = (0..<13_277).map { FileChange(path: "node_modules/pkg\($0 % 400)/f\($0).js", kind: .untracked, area: .untracked) }
        let status = RepoStatus(branch: BranchState(head: "main", oid: "x"), untracked: files + [FileChange(path: "README.md", kind: .modified, area: .unstaged)])
        let folded = lines(status)
        #expect(folded.count < 10, "one row per top folder, all folded")
        let open = lines(status, open: Set(folded.compactMap { if case .folder(_, let f, _) = $0.kind { f } else { nil } }))
        #expect(open.count == 3 + ChangeLines.rowLimit + 1, "header, folder, 300 files, 'and 12,977 more', README")
    }

    @Test func thePreviewKeepsEveryGroup() {
        let again = SnapshotFleet.bigRepo(staged: 12, unstaged: 20, editedAgain: 12)
        let all = lines(again.status!)
        #expect(all.count > ChangeList.inlineLines)
        let preview = ChangeLines.preview(all, rows: ChangeList.previewLines)
        #expect(preview.filter { if case .header = $0.kind { true } else { false } }.count == 2)
        #expect(preview.count == 2 + 5 + 5)
    }

    @Test func fileSlidesOnlyWhenItsPathIsInOneGroup() {
        let again = SnapshotFleet.bigRepo(staged: 3, unstaged: 2, editedAgain: 2)
        let movable = ChangeLines.pathsInOneGroup(ChangeSection.sections(of: again.status!))
        #expect(movable.count == 1 + 2, "file2 is only staged, two others only changed")
        #expect(!movable.contains("storefront-landing/src/components/file0.tsx"))
    }

    /// A 2,000- and a 13,277-file repo: building the rows stays far below a frame, and the
    /// card draws a bounded number of rows however many files there are.
    @Test func bigReposStaySmooth() {
        for (staged, unstaged) in [(2000, 0), (1598, 144), (0, 13_277)] {
            let repo = SnapshotFleet.bigRepo(staged: staged, unstaged: unstaged, editedAgain: 0)
            let clock = ContinuousClock()
            var result: [ChangeLines.Line] = []
            let elapsed = clock.measure { result = lines(repo.status!) }
            #expect(elapsed < .milliseconds(100), "\(staged)+\(unstaged) files took \(elapsed)")
            let drawn = result.count > ChangeList.inlineLines ? ChangeLines.preview(result, rows: ChangeList.previewLines).count : result.count
            #expect(drawn <= ChangeList.inlineLines)
        }
    }

    @Test func aTwoThousandFileCardRendersQuickly() throws {
        let repo = SnapshotFleet.bigRepo(staged: 2000, unstaged: 144, editedAgain: 20)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let host = NSHostingView(rootView: RepoSection(repo: repo).frame(width: 600))
            host.frame = CGRect(x: 0, y: 0, width: 600, height: 900)
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
        }
        #expect(elapsed < .milliseconds(500), "first layout took \(elapsed)")
    }
}
