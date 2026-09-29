import SwiftUI
import FerryKit

/// One line: name · branch · exceptional state (sync, stash, progress) · the repo's one
/// action when it has no local changes · "…". Each fact appears once: the change count
/// lives in the change list's group headers, ↑/↓ in the Sync button when it carries them.
struct RepoHeader: View {
    @Bindable var repo: RepoItem
    /// The repo's project name. Shown inline only when another repo has the same name;
    /// otherwise it lives in the name's tooltip and VoiceOver label.
    var projectCaption: String?
    /// Set when the card is collapsed: the header then offers "N changes ›" to open it.
    var collapsedChanges: Int? = nil
    @State private var showBranches = false
    @State private var showStashes = false
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        // One line when it fits with the branch truncated; then with "Publish" for
        // "Publish Branch"; only then state and action move to a second line. The name
        // and the button label never truncate.
        ViewThatFits(in: .horizontal) {
            oneLine(shortLabels: false)
            oneLine(shortLabels: true)
            twoLines
        }
        .labelStyle(.compactIcon)
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    private func oneLine(shortLabels: Bool) -> some View {
        HStack(spacing: 4) {
            name
            note
            branchOrLoadState
            stateChips
            Spacer(minLength: 8)
            quietButton(shortLabels: shortLabels)
            RepoMenu(repo: repo)
        }
    }

    private var twoLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                name
                note
                branchOrLoadState
                Spacer(minLength: 8)
                RepoMenu(repo: repo)
            }
            HStack(spacing: 4) {
                stateChips
                Spacer(minLength: 8)
                quietButton(shortLabels: false)
            }
        }
    }

    @ViewBuilder
    private var branchOrLoadState: some View {
        if let status = repo.status {
            branchButton(status.branch)
                // Measured as its glyph alone, so the branch truncates before the
                // header gives up its single line.
                .frame(idealWidth: 28)
        } else if let loadError = repo.loadError {
            Label(loadError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .frame(idealWidth: 28)
                .help(loadError)
        } else {
            Text("Reading status…")
                .foregroundStyle(.tertiary)
                .frame(idealWidth: 28)
        }
    }

    @ViewBuilder
    private var stateChips: some View {
        if let status = repo.status {
            if showsSyncChip(status) {
                SyncChip(state: status.syncState, freshness: repo.freshnessText)
                    .fixedSize()
                    .padding(.horizontal, 2)
            }
            if status.stashCount > 0 {
                stashButton(count: status.stashCount)
            }
            if let progress = repo.progressText, repo.activity != nil {
                Text(progress)
                    .truncationMode(.tail)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
                    .frame(idealWidth: 28)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func quietButton(shortLabels: Bool) -> some View {
        if let count = collapsedChanges {
            Button {
                Motion.animate { app?.currentRepoID = repo.id }
            } label: {
                HStack(spacing: 4) {
                    Text(count == 1 ? "1 change" : "\(count) changes")
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open to commit")
            .layoutPriority(1)
        } else if repo.status?.hasChanges == false {
            QuietPrimaryButton(repo: repo, shortLabels: shortLabels)
                .layoutPriority(1)
        }
    }

    /// Worktree / copies caption: the first thing to give way, before the branch.
    private var note: some View {
        RepoNoteView(repo: repo)
            .padding(.trailing, 4)
            .layoutPriority(-1)
    }

    private var name: some View {
        HStack(spacing: 6) {
            Text(displayName)
                .font(.headline)
                .fixedSize()
                .help(projectCaption.map { "\(displayName) — \($0)" } ?? displayName)
                .accessibilityLabel(projectCaption.map { "\(displayName), \($0)" } ?? displayName)
            if let projectCaption, nameIsAmbiguous {
                Text(projectCaption)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .padding(.trailing, 4)
        .layoutPriority(2)
    }

    private func branchButton(_ branch: BranchState) -> some View {
        Button {
            showBranches = true
        } label: {
            Label {
                Text(branch.head ?? "detached at \(branch.oid.map { String($0.prefix(7)) } ?? "?")")
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "arrow.triangle.branch")
            }
        }
        .buttonStyle(.accessoryBar)
        .foregroundStyle(.secondary)
        .disabled(repo.git == nil)
        .popover(isPresented: $showBranches, arrowEdge: .bottom) {
            BranchPicker(repo: repo)
        }
        .onChange(of: app?.branchPickerRequest) { _, request in
            guard request == repo.id else { return }
            app?.branchPickerRequest = nil
            // Give the stack a moment to scroll the card into view before anchoring.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                showBranches = true
            }
        }
        .help("Switch Branch (⌘B)")
        .accessibilityLabel("Branch \(branch.head ?? "detached"). Change branch")
    }

    private func stashButton(count: Int) -> some View {
        Button {
            showStashes = true
        } label: {
            Label("\(count)", systemImage: "tray.full")
                .monospacedDigit()
        }
        .buttonStyle(.accessoryBar)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("\(count) stashed change\(count == 1 ? "" : "s")")
        .accessibilityLabel("\(count) stashed change\(count == 1 ? "" : "s"). Show stashes")
        .popover(isPresented: $showStashes, arrowEdge: .bottom) {
            StashList(repo: repo)
        }
    }

    /// ↑/↓ and remote state, unless the quiet button already says it (Sync 2↑, Publish).
    private func showsSyncChip(_ status: RepoStatus) -> Bool {
        guard status.syncState != .upToDate else { return false }
        if !status.hasChanges {
            switch repo.primaryAction {
            case .sync, .publish: return false
            default: break
            }
        }
        return true
    }

    /// Another repo in the fleet has the same name, so the name alone doesn't say which one.
    private var nameIsAmbiguous: Bool {
        guard let app else { return false }
        let name = repo.name.lowercased()
        return app.allRepos.contains { $0.id != repo.id && $0.name.lowercased() == name }
    }

    private var displayName: String {
        app?.settings.privacyMode == true ? String(repeating: "•", count: min(repo.name.count, 10)) : repo.name
    }
}

/// ↑/↓ counts or a quiet state label.
struct SyncChip: View {
    var state: SyncState
    /// "fetched 2 min ago" — how current ↑/↓ are.
    var freshness: String = ""

    var body: some View {
        Group {
            switch state {
            case .ahead(let n):
                Label("\(n)", systemImage: "arrow.up")
                    .contentTransition(.numericText(value: Double(n)))
            case .behind(let n):
                Label("\(n)", systemImage: "arrow.down")
                    .contentTransition(.numericText(value: Double(n)))
            case .diverged(let a, let b):
                HStack(spacing: 6) {
                    Label("\(a)", systemImage: "arrow.up")
                    Label("\(b)", systemImage: "arrow.down")
                }
            case .unpublished:
                Label("Not published", systemImage: state.symbol)
            case .noRemote:
                Label("Local only", systemImage: state.symbol)
            case .upstreamGone:
                Label("Remote branch gone", systemImage: state.symbol)
            case .upToDate:
                Image(systemName: "checkmark")
            }
        }
        .foregroundStyle(state.tint)
        .monospacedDigit()
        .help(freshness.isEmpty ? state.description : "\(state.description) · \(freshness)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.description)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Publish / Sync button for a repo without local changes; a ✓ right after success.
/// Its label never truncates (the header picks `shortLabels` — "Publish" for "Publish
/// Branch" — when it runs out of room), and a push to a protected branch says so
/// ("Sync 2↑ to main").
struct QuietPrimaryButton: View {
    var repo: RepoItem
    var shortLabels = false

    var body: some View {
        Group {
            if let activity = repo.activity {
                BusyLabel(text: activity.verb)
            } else {
                switch repo.primaryAction {
                case .publish:
                    publishButton(shortLabels ? "Publish" : "Publish Branch")
                case .sync(let a, let b):
                    Button {
                        Task { await repo.sync() }
                    } label: {
                        Label(syncLabel(ahead: a, behind: b), systemImage: "arrow.triangle.2.circlepath")
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .help((protectedBranch.map { "Pull, then push to \($0), a protected branch" } ?? "Pull, then push") + (repo.freshnessText.isEmpty ? "" : " · \(repo.freshnessText)"))
                default:
                    if repo.isLingering {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: repo.successCount)
                            .accessibilityLabel("Done")
                            .transition(.opacity)
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
        .animation(Motion.snappy, value: repo.activity)
    }

    private func publishButton(_ title: String) -> some View {
        Button {
            Task { await repo.publish() }
        } label: {
            Label(title, systemImage: "icloud.and.arrow.up")
                .fixedSize()
        }
        .help("Push this branch to \(repo.status?.hasRemote == true ? "the remote" : "a remote") and track it")
        .accessibilityLabel("Publish Branch")
    }

    /// The branch name when this push lands on a protected branch.
    private var protectedBranch: String? {
        repo.warnsProtectedBranch ? repo.status?.branch.head : nil
    }

    private func syncLabel(ahead: Int, behind: Int) -> String {
        let title = Self.syncTitle(ahead: ahead, behind: behind)
        return protectedBranch.map { "\(title) to \($0)" } ?? title
    }

    static func syncTitle(ahead: Int, behind: Int) -> String {
        switch (ahead, behind) {
        case (let a, 0): "Sync \(a)↑"
        case (0, let b): "Sync \(b)↓"
        case (let a, let b): "Sync \(b)↓ \(a)↑"
        }
    }
}

struct BusyLabel: View {
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

/// The "…" menu with everything that isn't the primary action.
struct RepoMenu: View {
    var repo: RepoItem
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        Menu {
            RepoActionsMenuContent(repo: repo)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions for \(repo.name)")
    }
}

/// Shared by the "…" menu and the card's context menu.
struct RepoActionsMenuContent: View {
    var repo: RepoItem
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        let hasRemote = repo.status?.hasRemote ?? false
        let busy = repo.activity != nil
        Group {
            Button("Fetch", systemImage: "arrow.down.circle") { Task { await repo.fetch() } }
                .disabled(!hasRemote || busy)
            Button("Pull", systemImage: "arrow.down") { Task { await repo.pull() } }
                .disabled(repo.status?.branch.upstream == nil || busy)
            Button("Push", systemImage: "arrow.up") { Task { await repo.pushOrPublish() } }
                .disabled(!hasRemote || busy)
            Button("Sync", systemImage: "arrow.triangle.2.circlepath") { Task { await repo.sync() } }
                .disabled(repo.status?.branch.upstream == nil || busy)
            Divider()
            Button("Stash Changes", systemImage: "tray.and.arrow.down") { Task { await repo.stash() } }
                .disabled(!(repo.status?.hasChanges ?? false) || busy)
            Button("Undo Last Commit", systemImage: "arrow.uturn.backward") { Task { await repo.undoLastCommit() } }
                .disabled(!repo.lastCommitIsUnpushed || busy)
            Divider()
            Button("Open in Terminal", systemImage: "terminal") {
                Opener.openInTerminal(repo.path, bundleID: app?.settings.terminalBundleID ?? "")
            }
            Button("Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right") {
                Opener.openInEditor(repo.path, bundleID: app?.settings.editorBundleID ?? "")
            }
            Button("Reveal in Finder", systemImage: "folder") { Opener.reveal(repo.path) }
            Button("Copy Path", systemImage: "doc.on.doc") { Opener.copy(repo.path.path) }
            RepoOrganizeMenuItems(repo: repo)
        }
    }
}

/// Icon + short text, tighter than the default title-and-icon label.
struct CompactIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension LabelStyle where Self == CompactIconLabelStyle {
    static var compactIcon: CompactIconLabelStyle { .init() }
}
