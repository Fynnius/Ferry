import AppKit
import Observation
import FerryKit

enum SidebarItem: Hashable {
    case attention
    case all
    case project(String)
}

/// A repo to show, with the project caption used in cross-project lists. Its linked
/// worktrees that have something going on are drawn nested under it; clean ones only
/// appear in its worktrees menu.
struct StackEntry: Identifiable {
    var repo: RepoItem
    var projectName: String?
    var id: String { repo.id }
}

/// Repos that need the same kind of thing next ("Changes", "Ready to Push", …).
struct StackGroup: Identifiable {
    var urgency: RepoUrgency
    var entries: [StackEntry]
    var id: RepoUrgency { urgency }
}

/// The stack for one sidebar selection: groups in urgency order, each sorted by urgency
/// and most recent edit.
struct StackSections {
    var groups: [StackGroup] = []

    var entries: [StackEntry] { groups.flatMap(\.entries) }
    /// Every repo drawn, top to bottom.
    var repos: [RepoItem] { entries.map(\.repo) }
    var isEmpty: Bool { groups.isEmpty }

    func group(_ urgency: RepoUrgency) -> [StackEntry] {
        groups.first { $0.urgency == urgency }?.entries ?? []
    }

    /// Whether any group holds something that needs the user.
    var needsYou: Bool { groups.contains { $0.urgency.needsYou } }
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
    /// Cards the user opened (false) or folded (true) with the chevron, ←/→ or "N changes ›".
    /// Beats the automatic accordion until the repo has no changes left.
    var userFolded: [String: Bool] = [:]

    /// Up to this many repos with changes are all open (the VS Code feel); beyond it only
    /// one is, so the list stays readable at a glance.
    static let openAllLimit = 3

    /// Which repos with changes show as one collapsed row. The user's own open/fold wins;
    /// otherwise dormant repos fold, and beyond `openAllLimit` only one repo stays open.
    /// The accordion never folds a repo the user is in the middle of — typed message,
    /// running operation, visible problem.
    func collapsedRepoIDs(in shown: [RepoItem]) -> Set<String> {
        let dirty = shown.filter { $0.status?.hasChanges == true }
        var collapsed = Set(dirty.filter { $0.urgency == .dormant && !$0.isActive }.map(\.id))
        let accordion = dirty.filter { !collapsed.contains($0.id) }
        if accordion.count > Self.openAllLimit {
            let open = accordion.first { $0.id == currentRepoID }?.id
                ?? accordion.first { $0.id == openRepoID }?.id
                ?? accordion.first?.id
            collapsed.formUnion(accordion.filter { repo in
                repo.id != open
                    && repo.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && repo.activity == nil && repo.problem == nil && !repo.isGeneratingMessage
            }.map(\.id))
        }
        for repo in dirty {
            switch userFolded[repo.id] {
            case true?: collapsed.insert(repo.id)
            case false?: collapsed.remove(repo.id)
            case nil: break
            }
        }
        return collapsed
    }

    /// Opens or folds a card on purpose. Opening also makes it the current repo.
    func setFolded(_ repo: RepoItem, _ folded: Bool) {
        Motion.animate {
            userFolded[repo.id] = folded
            if !folded { currentRepoID = repo.id }
        }
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
    /// Hosts whose "needs a sign-in" notice the user dismissed this session.
    var dismissedSignInHosts: Set<String> = []
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
        currentRepo ?? entries(for: selection).groups.first { $0.urgency.needsYou }?.entries.first?.repo
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

    /// Fetches every repo without prompting: a missing credential joins the one sign-in
    /// notice per host instead of a banner on each repo (its button signs in once).
    func fetchAll() async {
        guard !isFetchingAll else { return }
        isFetchingAll = true
        dismissedSignInHosts = []
        await withTaskGroup(of: Void.self) { group in
            for repo in allRepos where repo.status?.hasRemote ?? true {
                group.addTask { [weak self] in
                    guard let self, await self.backgroundFetch(repo.id, showsFailures: true) == .success else { return }
                    await self.fetchedManually(repo)
                }
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

    /// Settings → General → Run Setup Again: forgets the folders, the last scan and every
    /// grouping change (renames, moves, hidden, pinned, snoozes), then shows setup. Nothing
    /// in the repos is touched. Preferences stay, and so does the OpenAI key — it only
    /// goes when removed in Settings → AI.
    func runSetupAgain() {
        try? FileManager.default.removeItem(at: fleetStore.settingsURL)
        try? FileManager.default.removeItem(at: fleetStore.lastScanURL)
        Task { [scheduler] in await scheduler?.stop() }
        watcher?.watch([])
        discovery = DiscoverySettings()
        lastScan = nil
        lastScanAt = nil
        grouping = Grouping()
        projects = []
        repos = [:]
        scanFound = []
        currentRepoID = nil
        openRepoID = nil
        userFolded = [:]
        dismissedSignInHosts = []
        fleetNotice = nil
        searchText = ""
        selection = .attention
        phase = .onboarding
    }

    /// Applies changed fetch settings.
    func fetchSettingsChanged() {
        startFetching()
    }

    /// Never prompts: a missing credential marks the repo `signInHost` (summed up in one
    /// notice above the stack) and the scheduler backs off until the user signs in.
    /// `showsFailures` (Fetch All) puts any other failure on the repo's card.
    func backgroundFetch(_ id: String, showsFailures: Bool = false) async -> FetchOutcome {
        guard let repo = repos[id], let git = repo.git, repo.activity == nil else { return .success }
        do {
            try await git.fetch(timeout: .seconds(120), allowPrompts: false)
            repo.signInHost = nil
            await repo.refresh()
            return .success
        } catch {
            if let error = error as? GitError, error.kind == .authenticationRequired {
                repo.signInHost = error.remoteHost ?? "the remote"
            } else if showsFailures, (error as? GitError)?.kind != .cancelled {
                repo.problem = RepoProblem(error)
            }
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

    /// Repos for the sidebar selection, grouped by what they need next. A worktree is a
    /// row of its own like any repo, but only while it has something going on; clean ones
    /// live in their repo's "…" menu. Needs Attention leaves out what's up to date.
    func entries(for selection: SidebarItem?) -> StackSections {
        let scope: [(ProjectItem, String?)] = switch selection {
        case .project(let id): projects.filter { $0.id == id }.map { ($0, nil) }
        default: projects.map { ($0, $0.name) }
        }
        var entries: [StackEntry] = []
        for (project, caption) in scope {
            for repo in project.repos {
                if repo.worktreeOf != nil, repo.urgency == .clear, !repo.isActive { continue }
                if selection == .attention, !repo.isActive, !repo.hasSomethingPending { continue }
                entries.append(StackEntry(repo: repo, projectName: caption))
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            entries = entries.filter { entry in
                entry.repo.name.localizedCaseInsensitiveContains(query)
                    || entry.projectName?.localizedCaseInsensitiveContains(query) == true
                    || (entry.repo.status?.branch.head?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        let grouped = Dictionary(grouping: entries) { groupUrgency(of: $0.repo) }
        return StackSections(groups: RepoUrgency.allCases.compactMap { urgency in
            guard let entries = grouped[urgency] else { return nil }
            return StackGroup(urgency: urgency, entries: entries.sorted { $0.repo.comesBefore($1.repo) })
        })
    }

    /// The group a repo shows in. A snoozed repo waits with the up-to-date ones.
    func groupUrgency(of repo: RepoItem) -> RepoUrgency {
        if repo.isSnoozed, !repo.isActive { return .clear }
        return repo.urgency
    }

    func title(for selection: SidebarItem?) -> String {
        switch selection {
        case .attention, nil: "Needs Attention"
        case .all: "All Repositories"
        case .project(let id): projects.first { $0.id == id }?.name ?? "Project"
        }
    }
}
