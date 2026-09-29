import Foundation

/// The user's corrections to the suggested grouping. They always beat the
/// heuristics and are keyed by stable ids, so they survive rescans. Overrides that
/// point at repos or projects no longer found are ignored, never errors: the repo may
/// be on an unplugged drive and come back.
public struct DiscoveryOverrides: Hashable, Sendable, Codable {
    public struct UserProject: Hashable, Sendable, Codable {
        public var id: ProjectID
        public var name: String
    }

    /// Renames of suggested projects (keyed by id or any alias).
    public var projectNames: [ProjectID: String]
    /// Projects the user made; kept even while empty.
    public var createdProjects: [UserProject]
    /// Repo → project it was moved to (`ProjectID.other` for "Other Repositories").
    /// If the target project no longer exists, the repo falls back to the heuristics.
    public var assignments: [RepoID: ProjectID]
    public var pinned: Set<RepoID>
    public var hidden: Set<RepoID>
    /// Pairs never suggested together again. Applied inside the grouper, which takes
    /// them via `ProjectGrouper.group(_:overrides:)`.
    public var notRelated: Set<RepoPair>
    /// Repos added by hand, outside any scan root; scanned as roots of depth 0.
    public var manualRepos: [URL]
    /// Which local copy of a duplicated repo Ferry shows and operates on.
    public var primaryCopies: [RepoID: URL]
    /// Repos snoozed out of Needs Attention, by path → the status fingerprint at the time.
    /// The snooze lasts while the fingerprint matches; any change in the repo ends it.
    public var snoozed: [String: String]

    public init(
        projectNames: [ProjectID: String] = [:],
        createdProjects: [UserProject] = [],
        assignments: [RepoID: ProjectID] = [:],
        pinned: Set<RepoID> = [],
        hidden: Set<RepoID> = [],
        notRelated: Set<RepoPair> = [],
        manualRepos: [URL] = [],
        primaryCopies: [RepoID: URL] = [:],
        snoozed: [String: String] = [:]
    ) {
        self.projectNames = projectNames
        self.createdProjects = createdProjects
        self.assignments = assignments
        self.pinned = pinned
        self.hidden = hidden
        self.notRelated = notRelated
        self.manualRepos = manualRepos
        self.primaryCopies = primaryCopies
        self.snoozed = snoozed
    }

    // MARK: - Editing

    public mutating func rename(_ project: ProjectID, to name: String) {
        if let index = createdProjects.firstIndex(where: { $0.id == project }) {
            createdProjects[index].name = name
        } else {
            projectNames[project] = name
        }
    }

    @discardableResult
    public mutating func createProject(named name: String, id: ProjectID = .userCreated()) -> ProjectID {
        createdProjects.append(UserProject(id: id, name: name))
        return id
    }

    public mutating func move(_ repo: RepoID, to project: ProjectID) {
        assignments[repo] = project
    }

    public mutating func setPinned(_ repo: RepoID, _ isPinned: Bool) {
        if isPinned { pinned.insert(repo) } else { pinned.remove(repo) }
    }

    public mutating func setHidden(_ repo: RepoID, _ isHidden: Bool) {
        if isHidden { hidden.insert(repo) } else { hidden.remove(repo) }
    }

    public mutating func markNotRelated(_ a: RepoID, _ b: RepoID) {
        guard a != b else { return }
        notRelated.insert(RepoPair(a, b))
    }

    public mutating func addManualRepo(_ url: URL) {
        let url = directoryURL(url.path)
        if !manualRepos.contains(url) { manualRepos.append(url) }
    }

    public mutating func choosePrimaryCopy(_ copy: URL, for repo: RepoID) {
        primaryCopies[repo] = directoryURL(copy.path)
    }

    // MARK: - Applying

    /// Applies everything except `notRelated` (which must shape the grouping itself) to a
    /// fresh grouping. Pure: same inputs, same output.
    public func apply(to grouping: Grouping) -> Grouping {
        var entries: [RepoEntry] = []
        var suggestedHome: [RepoID: ProjectID] = [:]
        for project in grouping.projects {
            for repo in project.repos {
                entries.append(repo)
                suggestedHome[repo.id] = project.id
            }
        }
        entries += grouping.other + grouping.hidden

        var projects = grouping.projects.map { project -> Project in
            var project = project
            project.repos = []
            return project
        }
        for created in createdProjects where !projects.contains(where: { $0.id == created.id }) {
            projects.append(Project(id: created.id, name: created.name, reasons: [.createdByUser], repos: [], isUserCreated: true))
        }
        func index(of id: ProjectID) -> Int? {
            projects.firstIndex { $0.id == id || $0.aliases.contains(id) }
        }

        var other: [RepoEntry] = []
        var hiddenRepos: [RepoEntry] = []
        for var entry in entries {
            if let chosen = primaryCopies[entry.id], let at = entry.copies.firstIndex(where: { $0.url.path == chosen.path }) {
                entry.copies.insert(entry.copies.remove(at: at), at: 0)
            }
            entry.isPinned = pinned.contains(entry.id)
            if hidden.contains(entry.id) {
                hiddenRepos.append(entry)
                continue
            }
            var target = suggestedHome[entry.id].flatMap(index(of:))
            if let assigned = assignments[entry.id] {
                if assigned == .other {
                    target = nil
                    entry.isPlacedByUser = true
                } else if let assignedIndex = index(of: assigned) {
                    target = assignedIndex
                    entry.isPlacedByUser = true
                }
            }
            if let target { projects[target].repos.append(entry) } else { other.append(entry) }
        }

        for i in projects.indices {
            if projects[i].isUserCreated {
                projects[i].name = createdProjects.first { $0.id == projects[i].id }?.name ?? projects[i].name
            } else if let name = projects[i].aliases.lazy.compactMap({ projectNames[$0] }).first ?? projectNames[projects[i].id] {
                projects[i].name = name
            }
            projects[i].repos = ProjectGrouper.sortedRepos(projects[i].repos)
        }
        // A suggestion emptied by moves and hides is gone; the user's own projects stay.
        projects.removeAll { !$0.isUserCreated && $0.repos.isEmpty }

        return Grouping(
            projects: ProjectGrouper.sortedProjects(projects),
            other: ProjectGrouper.sortedRepos(other),
            hidden: ProjectGrouper.sortedRepos(hiddenRepos)
        )
    }

    // MARK: - Codable

    /// Every field is optional on decode, so a file written by an older or newer Ferry
    /// still loads instead of costing the user their corrections.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            projectNames: try c.decodeIfPresent([ProjectID: String].self, forKey: .projectNames) ?? [:],
            createdProjects: try c.decodeIfPresent([UserProject].self, forKey: .createdProjects) ?? [],
            assignments: try c.decodeIfPresent([RepoID: ProjectID].self, forKey: .assignments) ?? [:],
            pinned: try c.decodeIfPresent(Set<RepoID>.self, forKey: .pinned) ?? [],
            hidden: try c.decodeIfPresent(Set<RepoID>.self, forKey: .hidden) ?? [],
            notRelated: try c.decodeIfPresent(Set<RepoPair>.self, forKey: .notRelated) ?? [],
            manualRepos: try c.decodeIfPresent([URL].self, forKey: .manualRepos) ?? [],
            primaryCopies: try c.decodeIfPresent([RepoID: URL].self, forKey: .primaryCopies) ?? [:],
            snoozed: try c.decodeIfPresent([String: String].self, forKey: .snoozed) ?? [:]
        )
    }
}

extension ProjectGrouper {
    /// Suggested grouping with the user's overrides applied — what the sidebar shows.
    public func group(_ scan: ScanResult, overrides: DiscoveryOverrides) -> Grouping {
        overrides.apply(to: group(scan, keepingApart: overrides.notRelated))
    }
}
