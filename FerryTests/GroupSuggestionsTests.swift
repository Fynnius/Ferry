import Foundation
import Testing
@testable import Ferry
import FerryKit

/// Stands in for Apple Intelligence: returns whatever the test says, and records what it
/// was asked.
private final class FakeSuggester: GroupSuggesting {
    var groups: [ProposedGroup]
    var asked: [GroupCandidate] = []

    init(_ groups: [ProposedGroup]) { self.groups = groups }

    func propose(for candidates: [GroupCandidate]) async throws -> [ProposedGroup] {
        asked = candidates
        return groups
    }
}

@MainActor
@Suite("Suggest Groups")
struct GroupSuggestionsTests {
    private func entry(_ path: String, remote: String? = nil) -> RepoEntry {
        let repo = DiscoveredRepo(url: URL(fileURLWithPath: path, isDirectory: true), remoteURL: remote)
        let identity = remote.flatMap(RemoteIdentity.init(remoteURL:))
        return RepoEntry(id: RepoID(remote: identity, path: path), remote: identity, copies: [RepoCopy(repo: repo)])
    }

    private var leftovers: [RepoEntry] {
        [
            entry("/code/Markets/MarketBTC", remote: "git@github.com:me/MarketBTC.git"),
            entry("/code/Markets/MarketTrader"),
            entry("/code/Saas/SignupKit"),
            entry("/code/Saas/SignupVerify"),
            entry("/code/AIBot/frontend"),
            entry("/code/AIBotCopy/frontend"),
        ]
    }

    @Test func modelSeesNamesFoldersAndOwnersWithUniqueLabels() async throws {
        let fake = FakeSuggester([])
        _ = try await GroupSuggestions.suggest(for: leftovers, using: fake)
        #expect(fake.asked.map(\.label) == ["MarketBTC", "MarketTrader", "SignupKit", "SignupVerify", "frontend (AIBot)", "frontend (AIBotCopy)"])
        #expect(fake.asked[0].folder == "Markets")
        #expect(fake.asked[0].owner == "me")
    }

    @Test func madeUpNamesSharedReposAndSingletonsAreDropped() async throws {
        let fake = FakeSuggester([
            ProposedGroup(name: " Markets ", repos: ["MarketBTC", "markettrader", "MarketGhost"]),
            ProposedGroup(name: "Trading", repos: ["MarketBTC", "SignupKit"]),
            ProposedGroup(name: "Signup", repos: ["SignupKit", "SignupVerify", "SignupKit"]),
            ProposedGroup(name: "Lonely", repos: ["frontend (AIBot)", "Nope"]),
            ProposedGroup(name: "  ", repos: ["frontend (AIBot)", "frontend (AIBotCopy)"]),
        ])
        let suggestions = try await GroupSuggestions.suggest(for: leftovers, using: fake)
        #expect(suggestions.map(\.name) == ["Markets", "Signup"])
        #expect(suggestions[0].members.map(\.label) == ["MarketBTC", "MarketTrader"])
        #expect(suggestions[1].members.map(\.label) == ["SignupKit", "SignupVerify"])
    }

    @Test func fewerThanTwoLeftoversNeverAskTheModel() async throws {
        let fake = FakeSuggester([ProposedGroup(name: "X", repos: ["MarketBTC", "MarketBTC"])])
        #expect(try await GroupSuggestions.suggest(for: [leftovers[0]], using: fake).isEmpty)
        #expect(fake.asked.isEmpty)
    }

    @Test func acceptedSuggestionsBecomeUserProjects() throws {
        let app = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!), dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())"))
        let candidates = GroupSuggestions.candidates(from: leftovers)
        let suggestion = GroupSuggestion(name: "Signup", members: [candidates[2], candidates[3]])
        app.createProjects(from: [suggestion])
        let project = try #require(app.discovery.overrides.createdProjects.first)
        #expect(project.name == "Signup")
        #expect(app.discovery.overrides.assignments[candidates[2].id] == project.id)
        #expect(app.discovery.overrides.assignments[candidates[3].id] == project.id)
        #expect(app.discovery.overrides.assignments[candidates[0].id] == nil)
    }

    @Test func aSuggestionNamedLikeAProjectJoinsIt() throws {
        let app = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "ferry-tests-\(UUID())")!), dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID())"))
        let existing = ProjectID("signup-project")
        app.grouping.projects = [Project(id: existing, name: "Signup", reasons: [], repos: [])]
        let candidates = GroupSuggestions.candidates(from: leftovers)
        app.createProjects(from: [GroupSuggestion(name: "signup", members: [candidates[2], candidates[3]])])
        #expect(app.discovery.overrides.createdProjects.isEmpty)
        #expect(app.discovery.overrides.assignments[candidates[2].id] == existing)
    }
}
