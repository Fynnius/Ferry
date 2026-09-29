import Foundation
import Testing
@testable import FerryKit

/// Commit context against real git: which files are collected, how, and that secrets never leave.
@Suite("Commit context collection (real git)")
struct CommitContextTests {
    private let secret = "sk-proj-FAKE-SECRET-0123456789"

    private func file(_ path: String, in context: CommitContext) throws -> CommitContext.File {
        try #require(context.files.first { $0.path == path }, "\(path) missing from \(context.files.map(\.path))")
    }

    private func diffText(_ file: CommitContext.File) -> String? {
        if case .diff(let text) = file.content { text } else { nil }
    }

    @Test func stagedChangesOnlyWhenSomethingIsStaged() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.makeRepo("app", files: ["a.txt": "one\n", "b.txt": "two\n"])
        try fx.write("a.txt", "one\nmore\n", in: repo.root)
        try fx.write("b.txt", "changed\n", in: repo.root)
        try fx.write("untracked.txt", "new\n", in: repo.root)
        try await fx.git(["add", "a.txt"], in: repo.root)

        let context = try await repo.commitContext()
        #expect(!context.includesAllChanges)
        #expect(context.files.map(\.path) == ["a.txt"])
        #expect(context.branch == "main")
        #expect(context.repositoryName == "app")
        #expect(context.recentSubjects == ["Initial commit"])
        let diff = try #require(diffText(try file("a.txt", in: context)))
        #expect(diff.hasPrefix("diff --git a/a.txt b/a.txt"))
        #expect(diff.contains("+more"))
    }

    @Test func everythingIncludingUntrackedWhenNothingIsStaged() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.makeRepo("app", files: [
            "README.md": "# App\n",
            "package-lock.json": "{\"v\": 1}\n",
            "old.txt": "bye\n",
            "logo.bin": "seed\n",
        ])
        try fx.write("README.md", "# App\n\nNow with docs.\n", in: repo.root)
        try fx.write("package-lock.json", "{\"v\": 2}\n", in: repo.root)
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("old.txt"))
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]).write(to: repo.root.appendingPathComponent("logo.bin"))
        try fx.write("Sources/New File.swift", "let answer = 42\n", in: repo.root)
        try Data([0x00, 0xFF, 0x10]).write(to: repo.root.appendingPathComponent("blob.dat"))

        let context = try await repo.commitContext()
        #expect(context.includesAllChanges)
        #expect(Set(context.files.map(\.path)) == ["README.md", "package-lock.json", "old.txt", "logo.bin", "Sources/New File.swift", "blob.dat"])

        #expect(try diffText(try file("README.md", in: context))?.contains("+Now with docs.") == true)
        #expect(try file("package-lock.json", in: context).content == .skipped(.lockfile))
        #expect(try file("logo.bin", in: context).content == .binary)
        #expect(try file("blob.dat", in: context).content == .binary)
        let deleted = try file("old.txt", in: context)
        #expect(deleted.change == .deleted)
        #expect(diffText(deleted)?.contains("-bye") == true)
        let added = try file("Sources/New File.swift", in: context)
        #expect(added.change == .added)
        #expect(diffText(added) == """
        diff --git a/Sources/New File.swift b/Sources/New File.swift
        new file mode 100644
        --- /dev/null
        +++ b/Sources/New File.swift
        @@ -0,0 +1 @@
        +let answer = 42
        """)
    }

    @Test func secretFilesAreNeverReadOrSent() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.makeRepo("app", files: [".env.production": "TOKEN=old\n", "App.swift": "print(1)\n"])
        let outside = fx.root.appendingPathComponent("id_rsa")
        try "PRIVATE \(secret)\n".write(to: outside, atomically: true, encoding: .utf8)

        try fx.write(".env", "OPENAI_API_KEY=\(secret)\n", in: repo.root)
        try fx.write(".env.production", "TOKEN=\(secret)\n", in: repo.root)
        try fx.write("certs/dev.pem", "-----BEGIN \(secret)-----\n", in: repo.root)
        try fx.write(".env.example", "OPENAI_API_KEY=\n", in: repo.root)
        try fx.write("App.swift", "print(2)\n", in: repo.root)
        // A harmless-looking link to a key elsewhere must not be followed.
        try FileManager.default.createSymbolicLink(at: repo.root.appendingPathComponent("notes.txt"), withDestinationURL: outside)

        for staged in [false, true] {
            if staged { try await fx.git(["add", "-A"], in: repo.root) }
            let context = try await repo.commitContext()
            #expect(context.includesAllChanges == !staged)
            #expect(try file(".env", in: context).content == .withheldSecret)
            #expect(try file(".env.production", in: context).content == .withheldSecret)
            #expect(try file("certs/dev.pem", in: context).content == .withheldSecret)
            #expect(try diffText(try file(".env.example", in: context))?.contains("+OPENAI_API_KEY=") == true)

            let prompt = CommitPromptBuilder().build(from: context)
            #expect(!prompt.user.contains(secret), "staged: \(staged)")
            #expect(prompt.user.contains("- .env (SKIPPED: looks like a secret file)"))
            #expect(prompt.user.contains("- .env.production (SKIPPED: looks like a secret file)"))
            #expect(prompt.user.contains("+print(2)"))
        }
    }

    @Test func repoWithNoCommitsYet() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.makeRepo("fresh")
        try fx.write("README.md", "# Fresh\n", in: repo.root)
        try fx.write("src/main.swift", "print(\"hi\")", in: repo.root)

        let all = try await repo.commitContext()
        #expect(all.includesAllChanges)
        #expect(all.recentSubjects.isEmpty)
        #expect(all.branch == "main")
        let main = try #require(diffText(try file("src/main.swift", in: all)))
        #expect(main.hasSuffix("+print(\"hi\")\n\\ No newline at end of file"))

        try await fx.git(["add", "README.md"], in: repo.root)
        let staged = try await repo.commitContext()
        #expect(!staged.includesAllChanges)
        #expect(staged.files.map(\.path) == ["README.md"])
        #expect(try diffText(try file("README.md", in: staged))?.contains("+# Fresh") == true)

        let prompt = CommitPromptBuilder().build(from: staged)
        #expect(prompt.user.contains("(none yet — this is the first commit)"))
    }

    @Test func stagedRenameAndAwkwardPaths() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.makeRepo("app", files: [
            "Docs/Old Name.md": "line 1\nline 2\nline 3\nline 4\n",
            "Grüße [draft]*.txt": "hallo\n",
            "HEAD": "not a ref\n",
        ])
        try await fx.git(["mv", "Docs/Old Name.md", "Docs/New Name.md"], in: repo.root)
        try fx.write("Grüße [draft]*.txt", "hallo welt\n", in: repo.root)
        try fx.write("HEAD", "still not a ref\n", in: repo.root)
        try await fx.git(["add", "-A"], in: repo.root)

        let context = try await repo.commitContext()
        let renamed = try file("Docs/New Name.md", in: context)
        #expect(renamed.change == .renamed(from: "Docs/Old Name.md"))
        #expect(diffText(renamed)?.contains("rename from Docs/Old Name.md") == true)
        #expect(try diffText(try file("Grüße [draft]*.txt", in: context))?.contains("+hallo welt") == true)
        #expect(try diffText(try file("HEAD", in: context))?.contains("+still not a ref") == true)
    }

    @Test func fileNamedHEADInAllChangesMode() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.makeRepo("app", files: ["HEAD": "a\n"])
        try fx.write("HEAD", "b\n", in: repo.root)
        let context = try await repo.commitContext()
        #expect(try diffText(try file("HEAD", in: context))?.contains("+b") == true)
    }

    /// A file turned into a symlink prints two patches for one numstat line, which
    /// exercises the per-file fallback.
    @Test func typeChangeFallsBackToPerFileDiffs() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.makeRepo("app", files: ["target.txt": "t\n", "link": "was a file\n", "z.txt": "z\n"])
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(atPath: repo.root.appendingPathComponent("link").path, withDestinationPath: "target.txt")
        try fx.write("z.txt", "zz\n", in: repo.root)
        try await fx.git(["add", "-A"], in: repo.root)
        let numstat = try await fx.runner.run(["diff", "--cached", "--numstat", "-z"], in: repo.root)
        let patch = try await fx.runner.run(["diff", "--cached", "--no-color", "--patch"], in: repo.root)
        #expect(GitRepository.parseNumstat(numstat.stdout).count < GitRepository.splitPatch(patch.text).count, "precondition: counts differ")

        let context = try await repo.commitContext()
        let link = try file("link", in: context)
        #expect(link.change == .typeChanged)
        #expect(diffText(link)?.contains("-was a file") == true)
        #expect(try diffText(try file("z.txt", in: context))?.contains("+zz") == true)
    }

    @Test func untrackedSizeLimitsAreHonoured() async throws {
        let fx = try await GitFixture.make()
        let repo = try await fx.makeRepo("app", files: ["README.md": "x\n"])
        try fx.write("big.txt", String(repeating: "a", count: 2_000) + "\n", in: repo.root)
        try fx.write("small.txt", "s\n", in: repo.root)
        try fx.write("medium.txt", String(repeating: "m", count: 300) + "\n", in: repo.root)

        let rules = CommitPromptRules(untrackedFileSizeLimit: 1_000, untrackedTotalReadLimit: 100)
        let context = try await repo.commitContext(rules: rules)
        #expect(try file("big.txt", in: context).content == .tooLarge(bytes: 2_001))
        #expect(try diffText(try file("small.txt", in: context)) != nil)
        #expect(try file("medium.txt", in: context).content == .notRead)
    }

    @Test func pathBatchesStayUnderTheLimitAndKeepRenamesTogether() {
        let changes = (0..<10).map { FileChange(path: "dir/file\($0).txt", kind: .modified, area: .staged) }
            + [FileChange(path: "new/name.txt", originalPath: "old/name.txt", kind: .renamed, area: .staged)]
        let batches = GitRepository.batches(changes, maxBytes: 60)
        #expect(batches.flatMap { $0 } == changes)
        #expect(batches.count > 1)
        for batch in batches.dropLast() {
            #expect(batch.reduce(0) { $0 + $1.path.utf8.count + 1 + ($1.originalPath.map { $0.utf8.count + 1 } ?? 0) } <= 60)
        }
        #expect(batches.last?.last?.originalPath == "old/name.txt")
    }

    @Test func parseNumstatHandlesRenamesAndBinaries() {
        let raw = "3\t1\tsrc/a.swift\0-\t-\tlogo.png\0" + "0\t0\t\0old name.txt\0new name.txt\0"
        let entries = GitRepository.parseNumstat(Data(raw.utf8))
        #expect(entries.map(\.path) == ["src/a.swift", "logo.png", "new name.txt"])
        #expect(entries.map(\.binary) == [false, true, false])
    }
}
