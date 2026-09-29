import Foundation
import Observation
import FerryKit

/// What a repo is busy doing right now, shown on its primary button.
enum RepoActivity: Hashable {
    case committing, pushing, pulling, syncing, publishing, fetching, staging, switchingBranch, stashing, working

    var verb: String {
        switch self {
        case .committing: "Committing…"
        case .pushing: "Pushing…"
        case .pulling: "Pulling…"
        case .syncing: "Syncing…"
        case .publishing: "Publishing…"
        case .fetching: "Fetching…"
        case .staging: "Updating…"
        case .switchingBranch: "Switching…"
        case .stashing: "Stashing…"
        case .working: "Working…"
        }
    }
}

/// A failed operation, phrased for the inline banner, with the fixes worth offering.
struct RepoProblem: Identifiable, Equatable {
    enum Fix: Hashable {
        case sync, publish, pull, showOutput, openTerminal, openSettings, retry
        /// Stash every change (untracked included), then run the refused operation again.
        case stashAndRetry(RetryIntent)
        /// Bring back the stash `stashAndRetry` made.
        case popStash(Stash)
    }

    /// An operation git refused because of local changes, kept so it can run again once
    /// they're stashed.
    enum RetryIntent: Hashable {
        case switchTo(Branch), pull, sync
    }

    let id = UUID()
    var message: String
    var output: String
    var fixes: [Fix]
    var isWarning: Bool
    /// A heads-up after something worked ("your changes are in the stash"), not a failure.
    var isInfo: Bool

    init(message: String, output: String = "", fixes: [Fix] = [], isWarning: Bool = false, isInfo: Bool = false) {
        self.message = message
        self.output = output
        self.fixes = fixes
        self.isWarning = isWarning
        self.isInfo = isInfo
    }

    /// `retry` is what to run again after stashing, for failures caused by local changes.
    init(_ error: Error, retry: RetryIntent? = nil) {
        guard let error = error as? GitError else {
            self.init(message: error.localizedDescription)
            return
        }
        var fixes: [Fix] = []
        var warning = false
        switch error.kind {
        case .pushRejectedBehind: fixes = [.sync]; warning = true
        case .noUpstream: fixes = [.publish]; warning = true
        case .hookFailed: fixes = [.showOutput]
        case .conflicts: fixes = [.openTerminal]
        case .authenticationRequired, .sshKeyRejected, .hostKeyVerificationFailed, .signingFailed: fixes = [.openTerminal, .showOutput]
        case .identityMissing, .divergedNeedsStrategy: fixes = [.openSettings]
        case .indexLocked, .network, .timedOut: fixes = [.retry]; warning = true
        case .localChangesWouldBeOverwritten, .unstagedChangesBlockRebase:
            warning = true
            if let retry { fixes = [.stashAndRetry(retry)] }
        case .unknown: fixes = [.showOutput]
        default: break
        }
        if !fixes.contains(.showOutput), !error.output.isEmpty, error.kind != .cancelled, error.kind != .nothingToCommit {
            fixes.append(.showOutput)
        }
        self.init(message: error.summary, output: error.output, fixes: fixes, isWarning: warning)
    }
}

/// The UI-facing state of one repository plus the actions on it. One instance per repo,
/// owned by `AppModel`. Every git operation goes through `perform`, which marks the repo
/// busy, maps failures to an inline problem, and refreshes afterwards.
@Observable
final class RepoItem: Identifiable {
    let id: String
    var name: String
    var path: URL
    let git: GitRepository?
    var status: RepoStatus?
    var message: String = ""
    var activity: RepoActivity?
    var problem: RepoProblem?
    var progressText: String?
    /// Bumped on each success, drives the ✓ bounce.
    var successCount = 0
    /// Bumped to shake the message field (empty message on commit).
    var shakeCount = 0
    /// Bumped to move keyboard focus into the message field.
    var focusMessageCount = 0
    var isGeneratingMessage = false
    var loadError: String?
    weak var app: AppModel?

    /// Identity in the discovery grouping (nil for worktrees and submodules).
    var entryID: RepoID?
    /// Caption such as "Worktree of harbor-web" or "2 copies on this Mac".
    var note: String?
    /// Every local copy of this repo, primary first, when it's cloned more than once.
    var copies: [URL] = []
    var isPinned = false
    /// When the remote was last fetched (FETCH_HEAD's date — also counts fetches made
    /// outside Ferry), so ↑/↓ can be trusted.
    var lastFetchedAt: Date?
    /// Digest of the current status, for snoozing (see `RepoStatus.fingerprint`).
    private(set) var statusFingerprint: String?

    /// Snoozed out of Needs Attention until anything in the repo changes.
    var isSnoozed: Bool {
        guard let statusFingerprint, let snoozed = app?.discovery.overrides.snoozed[path.path] else { return false }
        return snoozed == statusFingerprint
    }

    /// "fetched 2 min ago", for tooltips next to ↑/↓ and Sync.
    var freshnessText: String {
        guard status?.hasRemote == true else { return "" }
        guard let lastFetchedAt else { return "not fetched yet" }
        if Date.now.timeIntervalSince(lastFetchedAt) < 60 { return "fetched just now" }
        return "fetched \(lastFetchedAt.formatted(.relative(presentation: .named)))"
    }

    /// Fixed flag used by mockups; the live app derives it from settings.
    var isProtectedBranchOverride: Bool?

    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var isRetryingAfterStash = false

    init(id: String, name: String, path: URL, git: GitRepository? = nil, status: RepoStatus? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.git = git
        self.status = status
    }

    var primaryAction: PrimaryAction {
        status.map(PrimaryAction.init(status:)) ?? .none
    }

    var needsAttention: Bool {
        (!isSnoozed && (status?.needsAttention ?? false)) || (problem.map { !$0.isWarning && !$0.isInfo } ?? false)
    }

    /// Stays true for a moment after a successful operation, so a repo that just became
    /// clean shows its ✓ before settling out of the attention list.
    var isLingering = false

    /// Whether the stack shows this repo in its active section.
    var isActive: Bool { needsAttention || activity != nil || isLingering || problem != nil }

    var isProtectedBranch: Bool {
        if let isProtectedBranchOverride { return isProtectedBranchOverride }
        return app?.settings.isProtected(branch: status?.branch.head) ?? false
    }

    /// Warn about a protected branch only when work is headed to it — uncommitted
    /// changes or unpushed commits — so a clean `main` stays calm.
    var warnsProtectedBranch: Bool {
        guard isProtectedBranch, let status else { return false }
        return status.hasChanges || status.branch.ahead > 0
    }

    /// Commits that exist only locally, so undo/amend can't rewrite shared history.
    var lastCommitIsUnpushed: Bool {
        guard let status, status.branch.hasCommits else { return false }
        return status.branch.upstream == nil || status.branch.ahead > 0
    }

    // MARK: - Refresh

    /// Re-reads status. Overlapping calls coalesce into at most one follow-up refresh.
    func refresh() async {
        guard let git else { return }
        if refreshTask != nil {
            refreshAgain = true
            await refreshTask?.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                refreshAgain = false
                do {
                    let new = try await git.status()
                    if new != status {
                        Motion.animate { status = new }
                    }
                    statusFingerprint = Self.fingerprint(of: new, in: path)
                    lastFetchedAt = await Self.fetchDate(git)
                    app?.endSnoozeIfChanged(self)
                    if new.operation == .merge || new.operation == .cherryPick || new.operation == .revert, message.isEmpty {
                        message = (try? await preparedMessage(git)) ?? ""
                    }
                    loadError = nil
                } catch let error as GitError where error.kind == .notARepository {
                    loadError = "This folder is no longer a git repository."
                } catch {
                    loadError = (error as? GitError)?.summary ?? error.localizedDescription
                }
            } while refreshAgain
            PerfLog.mark("refreshed \(name)")
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    // MARK: - Operations

    /// Runs one operation: busy state, error mapping, refresh. Ignored while another runs.
    @discardableResult
    func perform(_ activity: RepoActivity, retry: RepoProblem.RetryIntent? = nil, _ work: @escaping (GitRepository) async throws -> Void) async -> Bool {
        guard let git, self.activity == nil else { return false }
        if [.pushing, .pulling, .syncing, .publishing, .fetching].contains(activity) {
            // Git may run Ferry's askpass helper for a password; let it take focus.
            AskpassHelper.allowPromptActivation()
        }
        self.activity = activity
        problem = nil
        progressText = nil
        let typingAtStart = AppModel.textFieldBeingEdited()
        var succeeded = false
        do {
            try await work(git)
            succeeded = true
        } catch let error as GitError where error.kind == .cancelled {
        } catch {
            if let gitError = error as? GitError {
                Log.git.error("git \(Self.subcommand(gitError.command), privacy: .public) failed (exit \(gitError.exitCode)): \(String(describing: gitError.kind), privacy: .public)")
            } else {
                Log.git.error("operation failed: \(error.localizedDescription, privacy: .public)")
            }
            problem = RepoProblem(error, retry: retry)
        }
        self.activity = nil
        progressText = nil
        await refresh()
        if succeeded {
            successCount += 1
            isLingering = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                Motion.animate { self?.isLingering = false }
            }
            // Stash-and-retry stays put: its "changes are in the stash" note must be seen.
            if [.committing, .pushing, .pulling, .syncing, .publishing].contains(activity), !isRetryingAfterStash {
                app?.repoFinished(self, typingAtStart: typingAtStart)
            }
        }
        return succeeded
    }

    /// The git verb for logs, without paths or messages.
    private static func subcommand(_ arguments: [String]) -> String {
        arguments.first { !$0.hasPrefix("-") } ?? "?"
    }

    enum AfterCommit { case nothing, push, sync }

    /// Commit or Commit All per the current state, then optionally push or sync.
    func commit(amend: Bool = false, then after: AfterCommit = .nothing) async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard amend || !text.isEmpty else {
            shakeCount += 1
            focusMessageCount += 1
            return
        }
        let all = status.map { $0.staged.isEmpty } ?? false
        let strategy = app?.settings.pullStrategy ?? .merge
        let committed = await perform(.committing) { git in
            try await git.commit(message: text, all: all && !amend, amend: amend)
        }
        guard committed else { return }
        message = ""
        switch after {
        case .nothing: break
        case .push: await pushOrPublish()
        case .sync:
            await perform(.syncing, retry: .sync) { [weak self] git in
                try await git.sync(fallback: strategy, onProgress: self?.progressHandler())
            }
        }
    }

    func pushOrPublish() async {
        if status?.branch.upstream == nil {
            await publish()
        } else {
            await perform(.pushing) { [weak self] git in try await git.push(onProgress: self?.progressHandler()) }
        }
    }

    func publish() async {
        await perform(.publishing) { [weak self] git in try await git.publish(onProgress: self?.progressHandler()) }
    }

    @discardableResult
    func sync() async -> Bool {
        let strategy = app?.settings.pullStrategy ?? .merge
        return await perform(.syncing, retry: .sync) { [weak self] git in try await git.sync(fallback: strategy, onProgress: self?.progressHandler()) }
    }

    @discardableResult
    func pull() async -> Bool {
        let strategy = app?.settings.pullStrategy ?? .merge
        return await perform(.pulling, retry: .pull) { [weak self] git in try await git.pull(fallback: strategy, onProgress: self?.progressHandler()) }
    }

    func push() async {
        await perform(.pushing) { [weak self] git in try await git.push(onProgress: self?.progressHandler()) }
    }

    func fetch() async {
        let ok = await perform(.fetching) { [weak self] git in try await git.fetch(onProgress: self?.progressHandler()) }
        if ok { await app?.fetchedManually(self) }
    }

    /// Runs the primary action shown on the button.
    func runPrimaryAction() async {
        switch primaryAction {
        case .commit: await commit()
        case .publish: await publish()
        case .sync: await sync()
        case .none: break
        }
    }

    func stage(_ files: [FileChange]) async {
        await perform(.staging) { git in try await git.stage(files) }
    }

    /// Stages conflicted files once they're resolved. Refuses files that still contain
    /// conflict markers, so a half-resolved file can't be committed by accident.
    func markResolved(_ files: [FileChange]) async {
        let unresolved = files.filter { file in
            guard let text = try? String(contentsOf: path.appendingPathComponent(file.path), encoding: .utf8) else { return false }
            return text.contains("\n<<<<<<< ") || text.hasPrefix("<<<<<<< ") || text.contains("\n>>>>>>> ")
        }
        guard unresolved.isEmpty else {
            let names = unresolved.map(\.fileName).joined(separator: ", ")
            problem = RepoProblem(message: "\(names) still \(unresolved.count == 1 ? "has" : "have") conflict markers (<<<<<<<). Resolve them in your editor first.", isWarning: true)
            return
        }
        await stage(files)
    }

    func unstage(_ files: [FileChange]) async {
        await perform(.staging) { git in try await git.unstage(files) }
    }

    func stageAll() async {
        await perform(.staging) { git in try await git.stageAll() }
    }

    func unstageAll() async {
        await perform(.staging) { git in try await git.unstageAll() }
    }

    /// Undoes the last (unpushed) commit and puts its message back in the field.
    func undoLastCommit() async {
        var restored: String?
        let ok = await perform(.working) { git in restored = try await git.undoLastCommit() }
        if ok, let restored, message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = restored
        }
    }

    func stash(message stashMessage: String? = nil) async {
        await perform(.stashing) { git in try await git.stash(message: stashMessage) }
    }

    @discardableResult
    func switchTo(_ branch: Branch) async -> Bool {
        await perform(.switchingBranch, retry: .switchTo(branch)) { git in try await git.switchTo(branch) }
    }

    /// Stashes every change (untracked included, with a message saying why) and runs the
    /// refused operation again. Never discards: the stash stays in the list whether or not
    /// the retry works, and success says where the changes went.
    func stashAndRetry(_ intent: RepoProblem.RetryIntent) async {
        let label = switch intent {
        case .switchTo(let branch): "Ferry: before switching to \(branch.nameWithoutRemote)"
        case .pull: "Ferry: before pulling"
        case .sync: "Ferry: before syncing"
        }
        var stashed: Stash?
        let ok = await perform(.stashing) { git in
            try await git.stash(message: label)
            stashed = try await git.stashes().first
        }
        guard ok else { return }
        isRetryingAfterStash = true
        defer { isRetryingAfterStash = false }
        let retried = switch intent {
        case .switchTo(let branch): await switchTo(branch)
        case .pull: await pull()
        case .sync: await sync()
        }
        guard retried else { return }
        problem = RepoProblem(
            message: "Your changes are in the stash. Pop them when you're ready.",
            fixes: stashed.map { [.popStash($0)] } ?? [],
            isInfo: true
        )
        // Stashing can reflow the stack (fewer repos with changes); keep the note in view.
        app?.scrollTarget = id
    }

    /// Pops the stash `stashAndRetry` made, found again by message and date since its
    /// place in the list may have moved.
    func popStash(_ stash: Stash) async {
        guard let current = try? await git?.stashes().first(where: { $0.message == stash.message && $0.date == stash.date }) else {
            problem = RepoProblem(message: "That stash is no longer in the stash list.", isWarning: true)
            return
        }
        await perform(.stashing) { git in try await git.popStash(current) }
    }

    /// Status plus the modification dates of the changed files, so editing an already
    /// modified file again also counts as a change (git's status alone wouldn't show it).
    private static func fingerprint(of status: RepoStatus, in root: URL) -> String {
        let paths = Set((status.staged + status.unstaged + status.untracked + status.conflicted).map(\.path)).sorted().prefix(500)
        let dates = paths.map { path -> String in
            let date = try? root.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return "\(path)@\(date?.timeIntervalSince1970 ?? 0)"
        }
        return status.fingerprint + ":" + String(dates.joined(separator: "|").hashValue64)
    }

    /// FETCH_HEAD's modification date: the last fetch, pull or sync, from Ferry or not.
    /// Worktrees share their main repo's, which sits two levels above the worktree git dir.
    private static func fetchDate(_ git: GitRepository) async -> Date? {
        guard let dir = try? await git.gitDirectory() else { return nil }
        var candidates = [dir.appendingPathComponent("FETCH_HEAD")]
        if dir.deletingLastPathComponent().lastPathComponent == "worktrees" {
            candidates.append(dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FETCH_HEAD"))
        }
        return candidates.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    /// Git's prepared message for a merge/cherry-pick/revert (MERGE_MSG), without comments.
    private func preparedMessage(_ git: GitRepository) async throws -> String {
        let file = try await git.gitDirectory().appendingPathComponent("MERGE_MSG")
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dismissProblem() {
        problem = nil
    }

    /// Live progress lines from fetch/push/pull ("Writing objects: 42%").
    private func progressHandler() -> @Sendable (String) -> Void {
        { [weak self] chunk in
            guard let line = chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last.map(String.init),
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            Task { @MainActor in self?.progressText = line.replacingOccurrences(of: "remote: ", with: "") }
        }
    }
}

/// A named group of repos, as shown in the sidebar.
@Observable
final class ProjectItem: Identifiable {
    let id: String
    var name: String
    var repos: [RepoItem]
    /// Why these repos were grouped, e.g. "From Harbor.code-workspace".
    var reason: String?
    /// Discovery identity, for renames and moves (nil in mockups).
    var projectID: ProjectID?
    var isUserCreated: Bool

    init(id: String, name: String, repos: [RepoItem], reason: String? = nil, projectID: ProjectID? = nil, isUserCreated: Bool = false) {
        self.id = id
        self.name = name
        self.repos = repos
        self.reason = reason
        self.projectID = projectID
        self.isUserCreated = isUserCreated
    }

    var isOther: Bool { projectID == .other }

    var attentionCount: Int { repos.filter(\.needsAttention).count }
}

private extension String {
    /// FNV-1a: a stable 64-bit hash (Swift's hashValue is seeded per launch).
    var hashValue64: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
