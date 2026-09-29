import Foundation
import Testing
@testable import FerryKit

private typealias File = CommitContext.File

private func diff(_ path: String, lines: Int, marker: String = "x") -> String {
    "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -1 +1,\(lines) @@\n"
        + (0..<lines).map { "+\(marker) line \($0)" }.joined(separator: "\n")
}

private func context(_ files: [File], subjects: [String] = ["Add login", "Fix crash"]) -> CommitContext {
    CommitContext(repositoryName: "app", branch: "main", recentSubjects: subjects, includesAllChanges: false, files: files)
}

@Suite("Commit prompt packing")
struct CommitPromptBuilderTests {
    @Test func secretPathsNeverLeakEvenWhenAContextCarriesTheirDiff() {
        let secret = "OPENAI_KEY=sk-live-DO-NOT-SEND"
        let files = [
            File(path: ".env", change: .modified, content: .diff("diff --git a/.env b/.env\n+\(secret)")),
            File(path: "config/prod.pem", change: .added, content: .diff("+\(secret)")),
            File(path: "new-name.txt", change: .renamed(from: "credentials.json"), content: .diff("+\(secret)")),
            File(path: "ios/GoogleService-Info.plist", change: .modified, content: .withheldSecret),
            File(path: "Sources/App.swift", change: .modified, content: .diff(diff("Sources/App.swift", lines: 2))),
        ]
        let prompt = CommitPromptBuilder().build(from: context(files))
        #expect(!prompt.user.contains(secret))
        #expect(!prompt.system.contains(secret))
        #expect(prompt.user.contains("- .env (SKIPPED: looks like a secret file)"))
        #expect(prompt.user.contains("- config/prod.pem (SKIPPED: looks like a secret file)"))
        #expect(prompt.user.contains("- new-name.txt (SKIPPED: looks like a secret file)"))
        #expect(prompt.user.contains("- ios/GoogleService-Info.plist (SKIPPED: looks like a secret file)"))
        #expect(prompt.user.contains("+x line 1"))
    }

    @Test(arguments: [
        (".env", true), (".env.local", true), (".envrc", true), ("api/.env.production", true),
        (".env.example", false), (".env.sample", false), ("docs/env.md", false),
        ("certs/server.KEY", true), ("id_rsa", true), ("id_rsa.pub", false), ("id_ed25519", true),
        ("config/credentials.yml.enc", true), ("k8s/secrets.yaml", true), (".npmrc", true),
        ("app/google-services.json", true), (".git/config", true), ("Sources/KeyboardView.swift", false),
    ])
    func secretPatterns(path: String, isSecret: Bool) {
        #expect(CommitPromptRules.default.isSecret(path) == isSecret)
    }

    @Test(arguments: [
        ("package-lock.json", CommitPromptRules.SkipReason.lockfile), ("web/yarn.lock", .lockfile), ("pnpm-lock.yaml", .lockfile),
        ("App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", .lockfile), ("Cargo.lock", .lockfile),
        ("public/app.min.js", .generated), ("dist/index.js", .generated), ("Sources/Model.generated.swift", .generated),
        ("web/build/out.css", .generated),
    ])
    func skipPatterns(path: String, reason: CommitPromptRules.SkipReason) {
        #expect(CommitPromptRules.default.skipReason(for: path) == reason)
        #expect(CommitPromptRules.default.skipReason(for: "Sources/Build.swift") == nil)
    }

    @Test func lockfilesAndBinariesAreListedNotDiffed() {
        let files = [
            File(path: "package-lock.json", change: .modified, content: .diff(diff("package-lock.json", lines: 3, marker: "LOCK"))),
            File(path: "Assets/logo.png", change: .added, content: .binary),
            File(path: "Vendor/huge.json", change: .added, content: .tooLarge(bytes: 300_000)),
            File(path: "README.md", change: .modified, content: .diff(diff("README.md", lines: 1))),
        ]
        let user = CommitPromptBuilder().build(from: context(files)).user
        #expect(!user.contains("LOCK line"))
        #expect(user.contains("- package-lock.json (modified; lockfile, diff omitted)"))
        #expect(user.contains("- Assets/logo.png (added; binary file, diff omitted)"))
        #expect(user.contains("- Vendor/huge.json (added; new file too large (300 KB), diff omitted)"))
        #expect(user.contains("- README.md (modified)"))
        #expect(user.contains("diff --git a/README.md b/README.md"))
    }

    @Test func packsSmallestFirst() {
        let files = [
            File(path: "big.swift", change: .modified, content: .diff(diff("big.swift", lines: 40))),
            File(path: "small.swift", change: .modified, content: .diff(diff("small.swift", lines: 2))),
            File(path: "medium.swift", change: .modified, content: .diff(diff("medium.swift", lines: 10))),
        ]
        let user = CommitPromptBuilder().build(from: context(files)).user
        let order = ["small.swift", "medium.swift", "big.swift"].map { user.range(of: "diff --git a/\($0)")!.lowerBound }
        #expect(order == order.sorted())
        // The file list keeps git's order.
        let list = ["big.swift", "small.swift", "medium.swift"].map { user.range(of: "- \($0) (modified)")!.lowerBound }
        #expect(list == list.sorted())
    }

    @Test func oversizedFileIsCutAtALineWithTheMarker() {
        let rules = CommitPromptRules(diffBudget: 10_000, perFileLimit: 500)
        let files = [File(path: "Long.swift", change: .modified, content: .diff(diff("Long.swift", lines: 200)))]
        let builder = CommitPromptBuilder(rules: rules)
        let packed = builder.pack(files)
        #expect(packed.placements == [.truncated])
        let piece = packed.diffs[0]
        #expect(piece.hasSuffix("\n... [diff truncated]"))
        #expect(piece.count <= 500 + "... [diff truncated]".count)
        let lastLine = piece.split(separator: "\n").dropLast().last!
        #expect(lastLine.hasPrefix("+x line "), "cut on a line boundary")
        #expect(builder.build(from: context(files)).user.contains("- Long.swift (modified; diff truncated)"))
    }

    @Test func filesBeyondTheBudgetAreListedByName() {
        let rules = CommitPromptRules(diffBudget: 1_000, perFileLimit: 800)
        let files = [
            File(path: "a.swift", change: .modified, content: .diff(diff("a.swift", lines: 5))),
            File(path: "b.swift", change: .modified, content: .diff(diff("b.swift", lines: 70, marker: "BBB"))),
            File(path: "c.swift", change: .deleted, content: .diff(diff("c.swift", lines: 100, marker: "CCC"))),
        ]
        let builder = CommitPromptBuilder(rules: rules)
        #expect(builder.pack(files).placements == [.included, .truncated, .overBudget])
        let user = builder.build(from: context(files)).user
        #expect(user.contains("- c.swift (deleted; diff omitted — over size budget)"))
        #expect(!user.contains("CCC line"))
        let diffSection = user.components(separatedBy: "Diff:\n")[1]
        #expect(diffSection.count < 1_000 + 200)
    }

    @Test func manyFilesCollapseTheList() {
        let rules = CommitPromptRules(maxListedFiles: 3)
        let files = (0..<10).map { File(path: "f\($0).txt", change: .added, content: .diff(diff("f\($0).txt", lines: 1))) }
        let user = CommitPromptBuilder(rules: rules).build(from: context(files)).user
        #expect(user.contains("- f2.txt (added)\n- … and 7 more files"))
        #expect(!user.contains("- f3.txt (added)"))
    }

    @Test func userMessageFollowsTheTemplate() {
        let files = [File(path: "README.md", change: .renamed(from: "Readme.txt"), content: .diff("diff --git a/Readme.txt b/README.md\nsimilarity index 100%"))]
        let ctx = CommitContext(repositoryName: "Ferry", branch: nil, recentSubjects: ["Add engine", "Scaffold app"], includesAllChanges: true, files: files)
        let user = CommitPromptBuilder().build(from: ctx).user
        #expect(user == """
        Repository: Ferry
        Branch: (detached HEAD)

        Recent commit subjects (for style reference only — do not copy their content):
        - Add engine
        - Scaffold app

        Changed files:
        - README.md (renamed from Readme.txt)

        Diff:
        diff --git a/Readme.txt b/README.md
        similarity index 100%

        Write the commit message now.
        """)
    }

    @Test func firstCommitAndNoTextDiffHavePlaceholders() {
        let files = [File(path: "icon.png", change: .added, content: .binary)]
        let user = CommitPromptBuilder().build(from: context(files, subjects: [])).user
        #expect(user.contains("(none yet — this is the first commit)"))
        #expect(user.contains("(no text diff available — see the file list)"))
    }

    // MARK: Style

    @Test func conventionalCommitDetectionUsesTheThreshold() {
        let seven = ["feat: a", "fix(ui): b", "chore!: c", "refactor(core)!: d", "docs: e", "test: f", "ci: g"]
        #expect(CommitPromptBuilder.usesConventionalCommits(seven + ["Plain", "Merge branch 'x'", "WIP"]))
        #expect(!CommitPromptBuilder.usesConventionalCommits(Array(seven.prefix(6)) + ["Plain", "Merge branch 'x'", "WIP", "Other"]))
        #expect(!CommitPromptBuilder.usesConventionalCommits([]))
        #expect(!CommitPromptBuilder.usesConventionalCommits(["feature: x", "fix:nospace"]))
        #expect(CommitPromptBuilder.usesConventionalCommits(["Fix: typo"]), "type match is case-insensitive")
    }

    @Test func systemPromptAddsTheConventionalRuleOnlyWhenDetected() {
        let conventional = CommitPromptBuilder().build(from: context([], subjects: ["feat: a", "fix: b"])).system
        let plain = CommitPromptBuilder().build(from: context([], subjects: ["Add a", "Fix b"])).system
        #expect(conventional.contains("follow Conventional Commits"))
        #expect(!plain.contains("follow Conventional Commits"))
        #expect(plain.hasPrefix("You are an assistant that writes git commit messages"))
        #expect(plain.contains("- Write ONLY the commit message text. No preamble, no explanation, no markdown code fences, no quotes around the message."))
    }
}
