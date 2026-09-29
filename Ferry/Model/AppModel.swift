import AppKit
import Observation
import FerryKit

enum SidebarItem: Hashable {
    case attention
    case all
    case project(String)
}

/// A repo to show, with the project caption used in cross-project lists.
struct StackEntry: Identifiable {
    var repo: RepoItem
    var projectName: String?
    var id: String { repo.id }
}

/// The app's single source of truth: git setup, the repo fleet, watching and fetching.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        /// Git can't be used; the message says why and what to do.
        case gitUnavailable(String)
        /// No folders chosen yet — first run.
        case onboarding
        case ready
    }

    var phase: Phase = .starting {
        didSet { if phase != oldValue { addDroppedFoldersIfReady() } }
    }
    let settings: AppSettings
    private(set) var runner: GitRunner?
    /// Set when the login shell couldn't be read, so hooks may miss tools.
    var shellWarning: String?
    var projects: [ProjectItem] = []
    var repos: [String: RepoItem] = [:]
    var selection: SidebarItem? = .attention
    var searchText = ""
    var isFetchingAll = false
    /// ⌘B: the repo whose branch picker should open (its header consumes and clears it).
    var branchPickerRequest: String?
    /// A repo the stack should scroll into view.
    var scrollTarget: String?
    /// A card that should take keyboard focus (Next Repo); the stack consumes and clears it.
    var focusCardRequest: String?
    /// Bumped by ⌘F to focus the filter field.
    var focusSearchCount = 0
    /// True while the sidebar is hidden (narrow window), so the stack's subtitle carries
    /// the attention count the sidebar would otherwise show.
    var isSidebarHidden = false
    var showsHistory = UserDefaults.standard.bool(forKey: "showsHistory") {
        didSet { UserDefaults.standard.set(showsHistory, forKey: "showsHistory") }
    }
    /// The repo commands act on (focused card, else last clicked).
    var currentRepoID: String? {
        didSet {
            if let id = currentRepoID, repos[id]?.status?.hasChanges == true { openRepoID = id }
        }
    }
    /// The repo with changes that stays open when there are too many to open them all.
    var openRepoID: String?

    /// Up to this many repos with changes are all open (the VS Code feel); beyond it only
    /// one is, so the list stays readable at a glance.
    static let openAllLimit = 3

    /// Which repos with changes show as one collapsed row. Repos the user is in the middle
    /// of — typed message, running operation, visible problem — never collapse.
    func collapsedRepoIDs(in active: [RepoItem]) -> Set<String> {
        let dirty = active.filter { $0.status?.hasChanges == true }
        guard dirty.count > Self.openAllLimit else { return [] }
        let open = dirty.first { $0.id == currentRepoID }?.id
            ?? dirty.first { $0.id == openRepoID }?.id
            ?? dirty.first?.id
        return Set(dirty.filter { repo in
            repo.id != open
                && repo.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && repo.activity == nil && repo.problem == nil && !repo.isGeneratingMessage
        }.map(\.id))
    }

    // Discovery (see AppModel+Fleet.swift)
    let fleetStore: DiscoveryStore
    var discovery = DiscoverySettings()
    var lastScan: ScanResult?
    var grouping = Grouping()
    var isScanning = false
    var scanProgress: ScanProgress?
    /// Repos streamed in by the running scan (onboarding shows them live).
    var scanFound: [DiscoveredRepo] = []
    /// A one-line announcement, e.g. new repos found by a rescan.
    var fleetNotice: String?
    /// Folders dropped or sent from Finder that wait for the fleet (or onboarding) to
    /// take them; see AppModel+Folders.swift.
    var droppedFolders: [URL] = []
    /// Set to ask for a name, then move this repo into a new project.
    var newProjectRequest: RepoItem?
    /// Set to ask for a new project name.
    var renameRequest: ProjectItem?

    var watcher: RepoWatcher?
    private var scheduler: FetchScheduler?
    private let network = NetworkConditions()

    /// No network: background fetch pauses and the toolbar says so.
    var isOffline = false
    /// When the folders were last scanned, to rescan on activation when it's stale.
    var lastScanAt: Date?

    init(settings: AppSettings = AppSettings(), dataDirectory: URL = AppModel.dataDirectory(), keychain: KeychainStore = KeychainStore()) {
        self.settings = settings
        self.keychain = keychain
        self.hasAIKey = keychain.hasKey
        self.fleetStore = DiscoveryStore(directory: dataDirectory)
        network.onChange { [weak self] online in
            Task { @MainActor in self?.isOffline = !online }
        }
        #if DEBUG
        isOffline = UserDefaults.standard.bool(forKey: "FerrySimulateOffline")
        #endif
        // Coming back to Ferry after cloning something in Terminal: pick it up.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.rescanIfStale() }
        }
    }

    var allRepos: [RepoItem] { projects.flatMap(\.repos) }
    var attentionCount: Int { allRepos.filter(\.needsAttention).count }
    var currentRepo: RepoItem? { currentRepoID.flatMap { repos[$0] } }

    /// What menu commands act on: the current repo, else the first one needing attention.
    var commandTarget: RepoItem? {
        currentRepo ?? entries(for: selection).active.first?.repo
    }

    // MARK: - Startup

    func start() async {
        guard phase == .starting || isGitUnavailable else { return }
        phase = .starting
        do {
            var shell = await ShellEnvironment.resolve()
            // Tells Ferry's binary it was launched by git as the askpass program.
            shell.variables[AskpassHelper.modeVariable] = "1"
            if case .fallback(let reason) = shell.source {
                shellWarning = "Ferry couldn't read your shell setup (\(reason)), so git hooks may not find tools like node."
            }
            let gitPath = settings.gitPath.isEmpty ? nil : settings.gitPath
            let installation = try await GitLocator.locate(configuredPath: gitPath, environment: shell)
            runner = GitRunner(installation: installation, shell: shell, askpassPath: AskpassHelper.path)
        } catch let error as GitLocatorError {
            phase = .gitUnavailable(error.description)
            return
        } catch {
            phase = .gitUnavailable(error.localizedDescription)
            return
        }
        await loadFleet()
    }

    private var isGitUnavailable: Bool {
        if case .gitUnavailable = phase { return true }
        return false
    }

    // MARK: - Refresh, watch, fetch

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for repo in allRepos {
                group.addTask { await repo.refresh() }
            }
        }
        PerfLog.mark("refreshed-all \(allRepos.count)")
        await scheduler?.update(repoIDs: fetchableRepoIDs)
    }

    /// Keeps background fetch in step with which repos have remotes.
    func refreshSchedule() async {
        await scheduler?.update(repoIDs: fetchableRepoIDs)
    }

    func fetchAll() async {
        guard !isFetchingAll else { return }
        isFetchingAll = true
        await withTaskGroup(of: Void.self) { group in
            for repo in allRepos where repo.status?.hasRemote ?? true {
                group.addTask { await repo.fetch() }
            }
        }
        isFetchingAll = false
    }

    func fetchedManually(_ repo: RepoItem?) async {
        guard let repo else { return }
        await scheduler?.fetchedManually(repo.id)
    }

    private var fetchableRepoIDs: [String] {
        allRepos.filter { $0.status?.hasRemote ?? false }.map(\.id)
    }

    func startWatching() {
        let watched = allRepos.map { WatchedRepo(id: $0.id, root: $0.path, gitDirectory: Self.linkedGitDirectory(of: $0.path)) }
        if watcher == nil {
            watcher = RepoWatcher { [weak self] ids in
                Task { @MainActor in self?.changed(ids) }
            }
        }
        watcher?.watch(watched)
    }

    /// For worktrees and submodules `.git` is a file pointing at the real git dir.
    static func linkedGitDirectory(of root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(".git")
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
        let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
    }

    private func changed(_ ids: Set<String>) {
        for id in ids {
            guard let repo = repos[id], repo.activity == nil else { continue }
            Task { await repo.refresh() }
        }
    }

    func startFetching() {
        if scheduler == nil {
            let network = network
            scheduler = FetchScheduler(
                policy: settings.fetchPolicy,
                canFetch: { network.allowsBackgroundFetch },
                fetch: { [weak self] id in await self?.backgroundFetch(id) ?? .failed }
            )
        }
        Task { [settings, scheduler] in
            await scheduler?.setPolicy(settings.fetchPolicy)
            if settings.autoFetch {
                await scheduler?.start()
            } else {
                await scheduler?.stop()
            }
        }
    }

    /// Applies changed fetch settings.
    func fetchSettingsChanged() {
        startFetching()
    }

    private func backgroundFetch(_ id: String) async -> FetchOutcome {
        guard let repo = repos[id], let git = repo.git, repo.activity == nil else { return .success }
        do {
            try await git.fetch(timeout: .seconds(120))
            await repo.refresh()
            return .success
        } catch {
            return FetchOutcome(error)
        }
    }

    // MARK: - Commit flow

    /// A question the window shows as an alert before an action runs.
    struct Confirmation: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var confirmTitle: String
        /// When set, the alert offers "Don't ask again for this repo".
        var suppressionRepoID: String?
        var action: () -> Void
    }

    var confirmation: Confirmation?
    private var protectedConfirmedThisSession: Set<String> = []

    /// Commit from the button, menu or ⌘↩. On a protected branch, asks once per session
    /// per repo (warn, never block).
    func requestCommit(_ repo: RepoItem, then after: RepoItem.AfterCommit = .nothing) {
        currentRepoID = repo.id
        let proceed = { _ = Task { await repo.commit(then: after) } }
        let hasMessage = !repo.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasMessage, repo.isProtectedBranch, let branch = repo.status?.branch.head,
              !settings.protectedBranchConfirmationSkipped.contains(repo.id),
              !protectedConfirmedThisSession.contains(repo.id) else {
            proceed()
            return
        }
        confirmation = Confirmation(
            title: "Commit directly to \(branch)?",
            message: "\(branch) is a protected branch in \(repo.name). Your commit goes straight onto it\(after == .nothing ? "" : " and to the remote").",
            confirmTitle: "Commit to \(branch)",
            suppressionRepoID: repo.id
        ) { [weak self] in
            self?.protectedConfirmedThisSession.insert(repo.id)
            proceed()
        }
    }

    /// Amends the last commit — only offered while it's unpushed, since Ferry never force-pushes.
    func requestAmend(_ repo: RepoItem) {
        currentRepoID = repo.id
        Task { await repo.commit(amend: true) }
    }

    // MARK: - AI messages

    /// What ✨ shares, in one place for the Settings footer and the first-use note.
    static let aiPrivacyText = "✨ sends the diff of what you're about to commit to OpenAI — never files that look like secrets (.env, keys). OpenAI doesn't train on API data by default and Ferry asks it not to store the response, but OpenAI keeps API requests in its abuse-monitoring logs for up to 30 days."

    private var generationTasks: [String: Task<Void, Never>] = [:]
    let keychain: KeychainStore
    /// Whether an API key is saved (checked without reading it).
    var hasAIKey: Bool

    func saveAIKey(_ key: String) throws {
        try keychain.save(key)
        hasAIKey = keychain.hasKey
    }

    func removeAIKey() throws {
        try keychain.delete()
        hasAIKey = keychain.hasKey
    }

    /// Streams a message for what's about to be committed into the field. The
    /// user's own text comes back if they cancel; nothing is committed automatically.
    func generateMessage(for repo: RepoItem) {
        guard let git = repo.git, !repo.isGeneratingMessage else { return }
        currentRepoID = repo.id
        let key: String?
        do {
            key = try keychain.read()
        } catch {
            repo.problem = RepoProblem(message: "Ferry couldn't read your API key from the Keychain.", fixes: [.openSettings], isWarning: true)
            return
        }
        guard let key, !key.isEmpty else {
            repo.problem = RepoProblem(message: "AI messages need an OpenAI API key. Add one in Settings → AI.", fixes: [.openSettings], isWarning: true)
            return
        }
        guard settings.aiNoticeAcknowledged else {
            // Once, before any code leaves the Mac: say what's sent and what OpenAI keeps.
            confirmation = Confirmation(
                title: "Send this diff to OpenAI?",
                message: Self.aiPrivacyText + " Ferry won't ask again; the details are in Settings → AI.",
                confirmTitle: "Write Message"
            ) { [weak self] in
                self?.settings.aiNoticeAcknowledged = true
                self?.generateMessage(for: repo)
            }
            return
        }
        repo.problem = nil
        repo.isGeneratingMessage = true
        let original = repo.message
        let generator = CommitMessageGenerator(configuration: .init(model: settings.aiModel))
        generationTasks[repo.id] = Task { [weak self, weak repo] in
            defer {
                repo?.isGeneratingMessage = false
                self?.generationTasks[repo?.id ?? ""] = nil
            }
            do {
                let context = try await git.commitContext()
                guard !context.files.isEmpty else { return }
                let prompt = CommitPromptBuilder().build(from: context)
                for try await text in generator.generate(prompt, apiKey: key) {
                    repo?.message = text
                }
            } catch is CancellationError {
                repo?.message = original
            } catch let error as CommitMessageError {
                repo?.message = original
                let fixes: [RepoProblem.Fix] = error.isFixedInSettings ? [.openSettings] : []
                repo?.problem = RepoProblem(message: error.userMessage, fixes: fixes, isWarning: true)
            } catch {
                repo?.message = original
                repo?.problem = RepoProblem(error)
            }
        }
    }

    func cancelMessageGeneration(for repo: RepoItem) {
        generationTasks[repo.id]?.cancel()
    }

    // MARK: - What the detail shows

    /// Repos for the sidebar selection, split into those that need the user and the rest.
    func entries(for selection: SidebarItem?) -> (active: [StackEntry], quiet: [StackEntry]) {
        let entries: [StackEntry]
        switch selection {
        case .project(let id):
            entries = projects.first { $0.id == id }?.repos.map { StackEntry(repo: $0, projectName: nil) } ?? []
        default:
            entries = projects.flatMap { project in project.repos.map { StackEntry(repo: $0, projectName: project.name) } }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? entries : entries.filter {
            $0.repo.name.localizedCaseInsensitiveContains(query)
                || ($0.projectName?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.repo.status?.branch.head?.localizedCaseInsensitiveContains(query) ?? false)
        }
        let active = filtered.filter { $0.repo.isActive }
        let quiet = selection == .attention ? [] : filtered.filter { !$0.repo.isActive }
        return (active, quiet)
    }

    func title(for selection: SidebarItem?) -> String {
        switch selection {
        case .attention, nil: "Needs Attention"
        case .all: "All Repositories"
        case .project(let id): projects.first { $0.id == id }?.name ?? "Project"
        }
    }
}
