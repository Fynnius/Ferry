import Foundation
import Testing
import Synchronization
@testable import FerryKit

@Suite("Repo watcher")
struct RepoWatcherTests {
    private let repos = [
        WatchedRepo(id: "app", root: URL(fileURLWithPath: "/w/app")),
        WatchedRepo(id: "nested", root: URL(fileURLWithPath: "/w/app/vendor/lib")),
        WatchedRepo(id: "wt", root: URL(fileURLWithPath: "/w/app-wt"), gitDirectory: URL(fileURLWithPath: "/w/app/.git/worktrees/app-wt")),
    ]

    @Test func mapsEventsToRepos() {
        #expect(RepoWatcher.repo(for: "/w/app/src", in: repos) == "app")
        #expect(RepoWatcher.repo(for: "/w/app", in: repos) == "app")
        #expect(RepoWatcher.repo(for: "/w/app/.git", in: repos) == "app")
        #expect(RepoWatcher.repo(for: "/w/app/.git/refs/heads", in: repos) == "app")
        #expect(RepoWatcher.repo(for: "/w/app/vendor/lib/x", in: repos) == "nested")
        #expect(RepoWatcher.repo(for: "/w/app/.git/worktrees/app-wt", in: repos) == "wt")
        #expect(RepoWatcher.repo(for: "/w/elsewhere", in: repos) == nil)
        #expect(RepoWatcher.repo(for: "/w/application", in: repos) == nil)
    }

    @Test func ignoresNoise() {
        #expect(RepoWatcher.repo(for: "/w/app/.git/objects/ab", in: repos) == nil)
        #expect(RepoWatcher.repo(for: "/w/app/.git/logs/refs", in: repos) == nil)
        #expect(RepoWatcher.repo(for: "/w/app/node_modules/react", in: repos) == nil)
        #expect(RepoWatcher.repo(for: "/w/app/web/.next/cache", in: repos) == nil)
        #expect(RepoWatcher.repo(for: "/w/app/.git/worktrees/app-wt/objects", in: repos) == nil)
    }

    @Test func reportsRealFileChangesDebounced() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-watch-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let batches = Mutex<[Set<String>]>([])
        let watcher = RepoWatcher(debounce: .milliseconds(200)) { ids in batches.withLock { $0.append(ids) } }
        watcher.watch([WatchedRepo(id: "r", root: dir)])
        try await Task.sleep(for: .milliseconds(300))

        for i in 0..<5 {
            try "\(i)".write(to: dir.appendingPathComponent("src/f\(i).txt"), atomically: true, encoding: .utf8)
        }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            if !batches.withLock({ $0.isEmpty }) { break }
        }
        watcher.stop()
        let received = batches.withLock { $0 }
        #expect(received.first == ["r"])
        #expect(received.count <= 2, "five writes should collapse into one or two refreshes")
    }
}

@Suite("Background fetch scheduling")
struct FetchSchedulerTests {
    @Test func policyBacksOffAndJitters() {
        let policy = FetchPolicy(interval: .seconds(180), jitter: 0.15, maxBackoff: .seconds(3600))
        #expect(policy.delay(after: .success, consecutiveFailures: 0, random: 0.5) == 180)
        #expect(policy.delay(after: .success, consecutiveFailures: 0, random: 0) == 180 * 0.85)
        #expect(policy.delay(after: .success, consecutiveFailures: 0, random: 1) == 180 * 1.15)
        #expect(policy.delay(after: .failed, consecutiveFailures: 2, random: 0.5) == 720)
        #expect(policy.delay(after: .authentication, consecutiveFailures: 1, random: 0.5) == 720)
        #expect(policy.delay(after: .authentication, consecutiveFailures: 5, random: 0.5) == 3600)
        #expect(policy.delay(after: .network, consecutiveFailures: 3, random: 0.5) == 180)
    }

    @Test func staggersNewReposAndSchedulesAfterOutcomes() async {
        let values = Mutex([0.0, 0.5, 0.99])
        let scheduler = FetchScheduler(random: { values.withLock { $0.isEmpty ? 0.5 : $0.removeFirst() } }, fetch: { _ in .success })
        let now = Date(timeIntervalSince1970: 1_000_000)
        await scheduler.update(repoIDs: ["a", "b", "c"], now: now)
        #expect(await scheduler.due(now: now).count == 1)
        #expect(await scheduler.due(now: now.addingTimeInterval(179)).count == 3)

        await scheduler.record(.authentication, for: "a", now: now)
        let next = await scheduler.nextDate(for: "a")
        #expect(next == now.addingTimeInterval(720))
        await scheduler.fetchedManually("a", now: now)
        #expect(await scheduler.nextDate(for: "a") == now.addingTimeInterval(180))

        await scheduler.update(repoIDs: ["a"], now: now)
        #expect(await scheduler.nextDate(for: "b") == nil)
    }

    @Test func outcomeFromGitErrors() {
        #expect(FetchOutcome(nil) == .success)
        #expect(FetchOutcome(GitError(kind: .network, command: [], exitCode: 128, stderr: "")) == .network)
        #expect(FetchOutcome(GitError(kind: .sshKeyRejected, command: [], exitCode: 128, stderr: "")) == .authentication)
        #expect(FetchOutcome(GitError(kind: .unknown, command: [], exitCode: 1, stderr: "")) == .failed)
    }
}
