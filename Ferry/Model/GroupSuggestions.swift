import Foundation
import FoundationModels
import FerryKit

/// "Suggest Groups…": Apple's on-device model proposes projects for the repos in Other
/// Repositories. Only folder names, their parent folder and the remote owner go in, and
/// nothing leaves the Mac. Proposals are checked against the real list and shown for the
/// user to accept; nothing is applied without them.

/// One repo as the model sees it. `label` is unique among the candidates (the folder
/// name, with its parent folder added when two repos share a name).
struct GroupCandidate: Hashable {
    var id: RepoID
    var label: String
    var folder: String
    var owner: String?
}

/// A group as the model returned it, before validation.
struct ProposedGroup: Hashable {
    var name: String
    var repos: [String]
}

/// A validated suggestion: a name and at least two repos, none shared with another one.
struct GroupSuggestion: Identifiable, Hashable {
    var name: String
    var members: [GroupCandidate]
    var id: String { members.map(\.id.rawValue).joined(separator: "|") }
}

/// The model call, behind a protocol so tests can stand in for Apple Intelligence.
protocol GroupSuggesting {
    func propose(for candidates: [GroupCandidate]) async throws -> [ProposedGroup]
}

enum GroupSuggestions {
    /// More names than this don't fit the on-device model's context comfortably.
    static let candidateLimit = 150

    /// Candidates from the grouping's leftovers, in their sidebar order.
    static func candidates(from entries: [RepoEntry]) -> [GroupCandidate] {
        let counts = Dictionary(grouping: entries, by: { $0.name.lowercased() }).mapValues(\.count)
        return entries.prefix(candidateLimit).map { entry in
            let folder = entry.primary.url.deletingLastPathComponent().lastPathComponent
            let label = (counts[entry.name.lowercased()] ?? 0) > 1 ? "\(entry.name) (\(folder))" : entry.name
            return GroupCandidate(id: entry.id, label: label, folder: folder, owner: entry.remote?.owner)
        }
    }

    /// Keeps only what's real: names the model made up are dropped, a repo joins at most
    /// one group (the first that names it), and a group needs two repos and a name.
    static func validated(_ proposed: [ProposedGroup], candidates: [GroupCandidate]) -> [GroupSuggestion] {
        let byLabel = Dictionary(candidates.map { ($0.label.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var used: Set<RepoID> = []
        var result: [GroupSuggestion] = []
        for group in proposed {
            var members: [GroupCandidate] = []
            for label in group.repos {
                guard let candidate = byLabel[label.trimmingCharacters(in: .whitespaces).lowercased()],
                      !used.contains(candidate.id), !members.contains(candidate) else { continue }
                members.append(candidate)
            }
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard members.count >= 2, !name.isEmpty else { continue }
            used.formUnion(members.map(\.id))
            result.append(GroupSuggestion(name: String(name.prefix(60)), members: members))
        }
        return result
    }

    static func suggest(for entries: [RepoEntry], using suggester: any GroupSuggesting) async throws -> [GroupSuggestion] {
        let candidates = candidates(from: entries)
        guard candidates.count >= 2 else { return [] }
        return validated(try await suggester.propose(for: candidates), candidates: candidates)
    }
}

extension AppModel {
    /// Accepted suggestions become projects the user made (overrides, so they survive
    /// rescans and can be renamed or undone like any other). A suggestion named like an
    /// existing project joins it instead of creating a second one with the same name.
    func createProjects(from suggestions: [GroupSuggestion]) {
        guard !suggestions.isEmpty else { return }
        for suggestion in suggestions {
            let existing = grouping.projects.first { $0.name.caseInsensitiveCompare(suggestion.name) == .orderedSame }?.id
            let id = existing ?? discovery.overrides.createProject(named: suggestion.name)
            for member in suggestion.members { discovery.overrides.move(member.id, to: id) }
        }
        if phase == .ready {
            saveDiscovery()
            regroup()
        } else if let lastScan {
            // Onboarding: only the review's grouping changes; finishing saves and starts the fleet.
            grouping = ProjectGrouper().group(lastScan, overrides: discovery.overrides)
        }
    }
}

// MARK: - Apple Intelligence

/// Whether the on-device model can run, and if not, a short reason for the UI.
enum AppleIntelligence {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Nil when available. On a Mac that can never run it the reason is nil too, so the
    /// feature just isn't offered there.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available, .unavailable(.deviceNotEligible): nil
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings to get group suggestions."
        case .unavailable(.modelNotReady): "Apple Intelligence is still getting ready. Try again in a little while."
        case .unavailable: "Apple Intelligence isn't available right now."
        }
    }
}

@Generable
nonisolated struct GeneratedGroups {
    @Guide(description: "Projects that clearly group several of the repositories. Leave out repositories that don't clearly belong with others.")
    var groups: [GeneratedGroup]
}

@Generable
nonisolated struct GeneratedGroup {
    @Guide(description: "A short project name, such as the product or topic the repositories share")
    var name: String
    @Guide(description: "Two or more repository names, copied exactly from the list")
    var repositories: [String]
}

struct AppleIntelligenceGrouper: GroupSuggesting {
    func propose(for candidates: [GroupCandidate]) async throws -> [ProposedGroup] {
        let session = LanguageModelSession(instructions: """
            You sort a developer's git repositories into projects. Put repositories in the \
            same project only when their names clearly show they belong together: parts of \
            one product (app, backend, website, admin), copies, forks or versions of one \
            repository, or one clear topic. Use repository names exactly as listed. Each \
            repository goes in at most one project. It is fine to leave most repositories \
            out; never make a project with a single repository.
            """)
        let list = candidates.map { candidate in
            var line = "- \(candidate.label) (in folder \(candidate.folder)"
            if let owner = candidate.owner { line += ", owner \(owner)" }
            return line + ")"
        }.joined(separator: "\n")
        let response = try await session.respond(to: "Repositories:\n\(list)", generating: GeneratedGroups.self)
        return response.content.groups.map { ProposedGroup(name: $0.name, repos: $0.repositories) }
    }
}
