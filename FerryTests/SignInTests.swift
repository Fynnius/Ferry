import Foundation
import Testing
@testable import Ferry
import FerryKit

@MainActor
@Suite("Sign-in: background fetch stays quiet (real git)")
struct SignInTests {
    private func app() -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!),
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())")
        )
    }

    /// A clone whose `origin` goes through a fake transport (`fake::…`) that fails the way
    /// an HTTPS remote without a credential does, and logs whether git offered it askpass.
    private func unsignedRepo(_ repos: TestRepos, model: AppModel) async throws -> (RepoItem, log: URL, bare: URL) {
        let bin = repos.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = repos.root.appendingPathComponent("remote.log")
        let helper = bin.appendingPathComponent("git-remote-fake")
        try """
        #!/bin/sh
        echo "askpass=${GIT_ASKPASS:-none}" >> "\(log.path)"
        echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2
        exit 128
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let plain = try await repos.clonedItem("app")
        let bare = repos.root.appendingPathComponent("app.git")
        try await repos.git(["remote", "set-url", "origin", "fake::https://github.com/acme/app"], in: plain.path)

        // Same isolated config, plus the fake transport on PATH and an askpass that must never run.
        var variables = repos.runner.baseEnvironment
        variables["PATH"] = "\(bin.path):\(ShellEnvironment.fallbackPath)"
        let runner = GitRunner(
            installation: repos.runner.installation,
            shell: ShellEnvironment(variables: variables, source: .fallback(reason: "tests")),
            askpassPath: "/usr/bin/false"
        )
        let item = RepoItem(id: plain.id, name: "app", path: plain.path, git: GitRepository(root: plain.path, runner: runner))
        item.app = model
        await item.refresh()
        model.projects = [ProjectItem(id: "p", name: "Project", repos: [item])]
        model.repos = [item.id: item]
        return (item, log, bare)
    }

    @Test func backgroundFetchNeverPromptsAndWaitsForSignIn() async throws {
        let repos = try await TestRepos()
        let model = app()
        let (item, log, bare) = try await unsignedRepo(repos, model: model)

        #expect(await model.backgroundFetch(item.id) == .authentication)
        #expect(item.signInHost == "github.com")
        #expect(item.problem == nil, "no banner from the background")
        #expect(item.freshnessText.contains("needs a sign-in"))
        #expect(try String(contentsOf: log, encoding: .utf8).contains("askpass=none"))
        #expect(model.signInGroups.map(\.host) == ["github.com"])
        #expect(model.signInGroups.first?.isGitHub == true)

        model.dismissSignInNotice(host: "github.com")
        #expect(model.signInGroups.isEmpty)

        // Once git can sign in, the waiting repos are fetched again and stop waiting.
        try await repos.git(["remote", "set-url", "origin", bare.path], in: item.path)
        await model.retryAfterSignIn(host: "github.com")
        #expect(item.signInHost == nil)
    }

    @Test func fetchAllGathersSignInsIntoOneNotice() async throws {
        let repos = try await TestRepos()
        let model = app()
        let (item, log, _) = try await unsignedRepo(repos, model: model)
        model.dismissSignInNotice(host: "github.com")

        await model.fetchAll()
        #expect(item.signInHost == "github.com")
        #expect(item.problem == nil, "no banner per repo")
        #expect(model.signInGroups.map(\.host) == ["github.com"], "Fetch All brings a dismissed notice back")
        #expect(try String(contentsOf: log, encoding: .utf8).contains("askpass=none"))
    }

    @Test func userStartedFetchMayPromptAndOffersSignIn() async throws {
        let repos = try await TestRepos()
        let model = app()
        let (item, log, _) = try await unsignedRepo(repos, model: model)

        await item.fetch()
        #expect(try String(contentsOf: log, encoding: .utf8).contains("askpass=/usr/bin/false"))
        #expect(item.problem?.fixes.first == .signIn)
    }

    @Test func onboardingHidesUncheckedReposAndStartsDormantOnesUnchecked() throws {
        let model = app()
        func repo(_ name: String, remote: String?, daysAgo: Double?) -> DiscoveredRepo {
            DiscoveredRepo(
                url: URL(fileURLWithPath: "/nowhere/\(name)", isDirectory: true),
                remoteURL: remote,
                lastActivity: daysAgo.map { Date(timeIntervalSinceNow: -$0 * 86_400) }
            )
        }
        model.lastScan = ScanResult(repos: [
            repo("active", remote: "https://github.com/acme/active.git", daysAgo: 3),
            repo("old", remote: "https://github.com/acme/old.git", daysAgo: 400),
            repo("ssh", remote: "git@github.com:acme/ssh.git", daysAgo: nil),
        ])
        model.regroup()
        let entries = model.grouping.visibleRepos
        let dormant = Set(entries.filter { AppModel.isDormant($0) }.map(\.name))
        #expect(dormant == ["old"])

        let old = try #require(entries.first { $0.name == "old" })
        #expect(model.httpsGitHubRepos(excluding: []).map(\.name).sorted() == ["active", "old"])
        #expect(model.httpsGitHubRepos(excluding: [old.id]).map(\.name) == ["active"])

        model.finishOnboarding(hiding: [old.id])
        #expect(model.grouping.hidden.map(\.name) == ["old"])
        #expect(model.discovery.overrides.hidden == [old.id])
        #expect(model.phase == .ready)
    }
}
