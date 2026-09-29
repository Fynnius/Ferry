import Foundation
import Testing
@testable import Ferry
import FerryKit

@MainActor
@Suite("Snooze and fetch freshness (real git)")
struct SnoozeAndFreshnessTests {
    private func app() -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!),
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())")
        )
    }

    @Test func snoozeHidesUntilTheRepoChanges() async throws {
        let repos = try await TestRepos()
        let model = app()
        let item = try await repos.clonedItem(app: model)
        try repos.write("a.txt", "a\n", in: item.path)
        await item.refresh()
        #expect(item.needsAttention)

        model.snooze(item)
        #expect(item.isSnoozed)
        #expect(!item.needsAttention)
        await item.refresh()
        #expect(item.isSnoozed, "a refresh with nothing new keeps the snooze")

        // Editing the same, already-modified file again ends it too.
        try await Task.sleep(for: .milliseconds(1100))
        try repos.write("a.txt", "a again\n", in: item.path)
        await item.refresh()
        #expect(!item.isSnoozed)
        #expect(item.needsAttention)
        #expect(model.discovery.overrides.snoozed.isEmpty, "a changed repo drops its stale snooze")
    }

    @Test func freshnessComesFromFetchHead() async throws {
        let repos = try await TestRepos()
        let item = try await repos.clonedItem()
        // A fresh clone has no FETCH_HEAD yet.
        #expect(item.lastFetchedAt == nil)
        #expect(item.freshnessText == "not fetched yet")
        await item.fetch()
        #expect(item.lastFetchedAt != nil)
        #expect(item.freshnessText == "fetched just now")
    }
}

@MainActor
@Suite("AI first-use note")
struct AINoticeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FERRY_SKIP_KEYCHAIN_TESTS"] == nil))
    func explainsWhatIsSentBeforeTheFirstGeneration() async throws {
        let keychain = KeychainStore(service: "io.github.fynnius.Ferry.tests.\(UUID().uuidString)")
        try keychain.save("sk-test-not-a-real-key")
        defer { try? keychain.delete() }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!)
        let model = AppModel(settings: settings, dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())"), keychain: keychain)
        let repos = try await TestRepos()
        let item = try await repos.clonedItem(app: model)
        try repos.write("a.txt", "a\n", in: item.path)
        await item.refresh()

        model.generateMessage(for: item)
        let note = try #require(model.confirmation)
        #expect(note.message.contains("30 days"))
        #expect(!item.isGeneratingMessage, "nothing is sent before the user agrees")
        // The confirm action would start a real request; not run here.
    }
}
