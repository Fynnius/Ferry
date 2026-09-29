import AppKit
import FerryKit

/// Discovery: which folders are scanned, how repos group into projects, and the user's
/// overrides. Settings and the last scan persist in Application Support.
extension AppModel {
    static func dataDirectory() -> URL {
        let defaults = UserDefaults.standard
        if let override = defaults.string(forKey: "FerryDataDirectory") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // Development runs with -FerryRoots never touch the real saved settings.
        if defaults.string(forKey: "FerryRoots") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ferry-dev-data", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Ferry", isDirectory: true)
    }

    // MARK: - Loading and scanning

    /// Launch: show the last scan's repos at once, then rescan in the background and
    /// announce what's new.
    func loadFleet() async {
        discovery = fleetStore.loadSettings()
        if let override = UserDefaults.standard.string(forKey: "FerryRoots") {
            discovery.roots = override.split(separator: ":").map { ScanRoot(url: URL(fileURLWithPath: String($0))) }
        }
        guard !discovery.roots.isEmpty else {
            phase = .onboarding
            return
        }
        if lastScan == nil, let saved = fleetStore.loadLastScan() {
            lastScan = saved
            regroup()
        }
        phase = .ready
        await rescan(announceNew: lastScan != nil)
    }

    /// Scans all roots again. New repos appear with a short notice; removed ones just go.
    func rescan(announceNew: Bool = true) async {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = nil
        let scanner = RepoScanner(runner: runner)
        let result = await scanner.scan(discovery.scanRoots) { [weak self] event in
            if case .progress(let progress) = event {
                Task { @MainActor in self?.scanProgress = progress }
            }
        }
        isScanning = false
        lastScanAt = .now
        Log.discovery.info("scan found \(result.repos.count) repos in \(self.discovery.roots.count) folders")
        let diff = ScanDiff(from: lastScan, to: result)
        lastScan = result
        try? fleetStore.saveLastScan(result)
        regroup()
        if announceNew {
            announce(diff)
        }
    }

    /// Rescans when Ferry comes to the front and the last scan is over 5 minutes old.
    func rescanIfStale() async {
        guard phase == .ready, !isScanning else { return }
        if let lastScanAt, Date.now.timeIntervalSince(lastScanAt) < 300 { return }
        await rescan()
    }

    private func announce(_ diff: ScanDiff) {
        let names = diff.newRepos.map(\.name)
        guard !names.isEmpty else { return }
        let list = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
        fleetNotice = names.count == 1 ? "New repo found: \(list)" : "\(names.count) new repos found: \(list)"
    }

    // MARK: - First run

    /// Onboarding step 3: scans the chosen folders, streaming repos into `scanFound`.
    func startOnboardingScan(roots: [URL]) async {
        discovery.roots = roots.map { ScanRoot(url: $0) }
        scanFound = []
        isScanning = true
        let scanner = RepoScanner(runner: runner)
        for await event in scanner.events(for: discovery.scanRoots) {
            switch event {
            case .progress(let progress):
                scanProgress = progress
            case .found(let repo):
                if case .repository = repo.kind { scanFound.append(repo) }
            case .foundBareRepository:
                break
            case .finished(let result):
                lastScan = result
                grouping = ProjectGrouper().group(result, overrides: discovery.overrides)
            }
        }
        isScanning = false
    }

    /// Onboarding done: persist the folders and scan, show the main window.
    func finishOnboarding() {
        saveDiscovery()
        if let lastScan { try? fleetStore.saveLastScan(lastScan) }
        regroup()
        selection = .attention
        phase = .ready
    }

    // MARK: - Grouping → sidebar

    func regroup() {
        guard let lastScan else { return }
        grouping = ProjectGrouper().group(lastScan, overrides: discovery.overrides)
        applyGrouping()
    }

    /// Rebuilds projects and repo items from the grouping, reusing existing items (and
    /// whatever message the user was typing) by path.
    private func applyGrouping() {
        guard let runner else { return }
        var next: [String: RepoItem] = [:]

        func item(_ repo: DiscoveredRepo, name: String, entry: RepoEntry?, note: String?) -> RepoItem {
            let id = repo.url.path
            let item = repos[id] ?? RepoItem(
                id: id,
                name: name,
                path: repo.url,
                git: repo.isDownloaded ? GitRepository(root: repo.url, runner: runner) : nil
            )
            item.name = name
            item.entryID = entry?.id
            item.note = note
            item.copies = entry.map { $0.copies.map(\.url) } ?? []
            item.isPinned = entry?.isPinned ?? false
            if !repo.isDownloaded {
                item.loadError = "Not downloaded from iCloud yet. Download it in Finder to use it here."
            }
            item.app = self
            next[id] = item
            return item
        }

        func items(_ entry: RepoEntry) -> [RepoItem] {
            let primary = entry.primary
            var list = [item(primary.repo, name: entry.name, entry: entry, note: entry.duplicateSummary)]
            for worktree in primary.worktrees {
                list.append(item(worktree, name: worktree.name, entry: nil, note: "Worktree of \(entry.name)"))
            }
            for submodule in primary.submodules {
                list.append(item(submodule, name: submodule.name, entry: nil, note: "Submodule of \(entry.name)"))
            }
            return list
        }

        var result = grouping.projects.map { project in
            ProjectItem(
                id: project.id.rawValue,
                name: project.name,
                repos: project.repos.flatMap { items($0) },
                reason: project.why,
                projectID: project.id,
                isUserCreated: project.isUserCreated
            )
        }
        if !grouping.other.isEmpty {
            result.append(ProjectItem(id: ProjectID.other.rawValue, name: Grouping.otherTitle, repos: grouping.other.flatMap { items($0) }, reason: Grouping.otherWhy, projectID: .other))
        }

        let added = next.keys.filter { repos[$0] == nil }
        projects = result
        repos = next
        if case .project(let id) = selection, !projects.contains(where: { $0.id == id }) {
            selection = .attention
        }
        if let current = currentRepoID, next[current] == nil { currentRepoID = nil }
        startWatching()
        startFetching()
        Task {
            await withTaskGroup(of: Void.self) { group in
                for id in added {
                    guard let repo = next[id] else { continue }
                    group.addTask { await repo.refresh() }
                }
            }
            await refreshSchedule()
        }
    }

    // MARK: - Folders

    /// File ▸ Add Folder…
    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders that contain git repositories. Ferry looks up to 6 levels deep."
        guard panel.runModal() == .OK else { return }
        addRoots(panel.urls)
    }

    func addRoots(_ urls: [URL]) {
        for url in urls where !discovery.roots.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            discovery.roots.append(ScanRoot(url: url))
        }
        saveDiscovery()
        if phase == .ready {
            Task { await rescan() }
        } else {
            Task { await loadFleet() }
        }
    }

    func removeRoot(_ root: ScanRoot) {
        discovery.roots.removeAll { $0 == root }
        saveDiscovery()
        Task { await rescan(announceNew: false) }
    }

    /// Adds one repo folder directly (it's scanned on its own, at depth 0).
    func addRepositoryManually() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateOverrides { $0.addManualRepo(url) }
        Task { await rescan() }
    }

    // MARK: - Overrides (always beat the heuristics, survive rescans)

    func renameProject(_ project: ProjectItem, to name: String) {
        guard let id = project.projectID, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        updateOverrides { $0.rename(id, to: name.trimmingCharacters(in: .whitespaces)) }
    }

    func move(_ repo: RepoItem, to project: ProjectID) {
        guard let entry = repo.entryID else { return }
        updateOverrides { $0.move(entry, to: project) }
    }

    func moveToNewProject(_ repo: RepoItem, named name: String) {
        guard let entry = repo.entryID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        updateOverrides { overrides in
            let id = overrides.createProject(named: trimmed)
            overrides.move(entry, to: id)
        }
    }

    func setHidden(_ repo: RepoItem, _ hidden: Bool) {
        guard let entry = repo.entryID else { return }
        updateOverrides { $0.setHidden(entry, hidden) }
    }

    func unhide(_ entry: RepoID) {
        updateOverrides { $0.setHidden(entry, false) }
    }

    func setPinned(_ repo: RepoItem, _ pinned: Bool) {
        guard let entry = repo.entryID else { return }
        updateOverrides { $0.setPinned(entry, pinned) }
    }

    /// Duplicates: make another local copy the one Ferry shows.
    func usePrimaryCopy(_ url: URL, for repo: RepoItem) {
        guard let entry = repo.entryID else { return }
        updateOverrides { $0.choosePrimaryCopy(url, for: entry) }
    }

    // MARK: - Snooze (stored with the overrides; ends when the repo changes)

    func snooze(_ repo: RepoItem) {
        guard let fingerprint = repo.statusFingerprint else { return }
        Motion.animate { discovery.overrides.snoozed[repo.path.path] = fingerprint }
        saveDiscovery()
    }

    func unsnooze(_ repo: RepoItem) {
        Motion.animate { discovery.overrides.snoozed[repo.path.path] = nil }
        saveDiscovery()
    }

    /// Drops a snooze whose repo has changed since, so it can't linger.
    func endSnoozeIfChanged(_ repo: RepoItem) {
        guard let snoozed = discovery.overrides.snoozed[repo.path.path],
              let current = repo.statusFingerprint, snoozed != current else { return }
        discovery.overrides.snoozed[repo.path.path] = nil
        saveDiscovery()
    }

    /// Projects a repo can be moved to, for the Move to Project menu.
    var moveTargets: [(id: ProjectID, name: String)] {
        projects.compactMap { project in project.projectID.map { ($0, project.name) } }
    }

    private func updateOverrides(_ change: (inout DiscoveryOverrides) -> Void) {
        change(&discovery.overrides)
        saveDiscovery()
        regroup()
    }

    func saveDiscovery() {
        try? fleetStore.save(discovery)
    }
}
