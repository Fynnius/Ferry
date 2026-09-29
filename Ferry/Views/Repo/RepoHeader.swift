import SwiftUI
import FerryKit

/// Column widths shared by every row of the stack, so names, branches and states line
/// up down the whole list like a table. Nil when the window is too narrow for columns.
struct StackColumns: Equatable {
    var name: CGFloat
    var branch: CGFloat

    /// Columns for rows `width` wide, or nil below a width where they'd squeeze.
    static func forRowWidth(_ width: CGFloat) -> StackColumns? {
        guard width >= 620 else { return nil }
        return StackColumns(name: min(max(width * 0.26, 170), 280), branch: min(max(width * 0.2, 140), 220))
    }
}

extension EnvironmentValues {
    @Entry var stackColumns: StackColumns? = nil
}

/// One row: disclosure · name · branch · state · the repo's one action · "…". The state
/// column says what the repo needs in words and its status colour ("3 changes",
/// "2 to push", "34 to pull"); the button only acts. On narrow windows the same pieces
/// flow on one line, and wrap to two when they must.
struct RepoHeader: View {
    @Bindable var repo: RepoItem
    /// The repo's project name. Shown only when another repo has the same name.
    var projectCaption: String?
    /// True when the row is folded: its changes are summed up and a click opens it.
    var isFolded = false
    @State private var showBranches = false
    @State private var showStashes = false
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(\.stackColumns) private var columns

    var body: some View {
        Group {
            if let columns {
                HStack(spacing: 8) {
                    disclosure
                    nameCell.frame(width: columns.name, alignment: .leading)
                    branchCell.frame(width: columns.branch, alignment: .leading)
                    stateCell.frame(maxWidth: .infinity, alignment: .leading)
                    actionCell
                    RepoMenu(repo: repo)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        disclosure
                        nameCell.fixedSize()
                        branchCell.frame(idealWidth: 28)
                        // Never truncated: when it doesn't fit, the row takes two lines.
                        stateCell.fixedSize()
                        Spacer(minLength: 8)
                        actionCell
                        RepoMenu(repo: repo)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            disclosure
                            nameCell
                            branchCell.frame(idealWidth: 28)
                            Spacer(minLength: 8)
                            RepoMenu(repo: repo)
                        }
                        HStack(spacing: 8) {
                            stateCell
                            Spacer(minLength: 8)
                            actionCell
                        }
                        .padding(.leading, Self.contentInset)
                    }
                }
            }
        }
        .labelStyle(.compactIcon)
        .lineLimit(1)
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
    }

    /// Where names start: past the disclosure. The expanded row's content lines up here.
    static let contentInset: CGFloat = 24

    /// Opens and folds a repo with changes, like a Finder outline. The only click that
    /// folds, so a stray click elsewhere can't hide work (a click on a folded row opens it).
    @ViewBuilder
    private var disclosure: some View {
        if repo.status?.hasChanges == true {
            Button {
                app?.setFolded(repo, !isFolded)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFolded ? "Open (→)" : "Fold (←). Nothing is lost; your message stays.")
            .accessibilityLabel(isFolded ? "Open \(repo.name)" : "Fold \(repo.name)")
        } else {
            Color.clear.frame(width: 16, height: 1)
        }
    }

    // MARK: Name

    private var nameCell: some View {
        HStack(spacing: 6) {
            Text(displayName)
                .font(.headline)
                .truncationMode(.middle)
                .layoutPriority(2)
                .help(nameHelp)
                .accessibilityLabel(worktreeParent.map { "\(displayName), worktree of \(privacy($0.name))" } ?? projectCaption.map { "\(displayName), \($0)" } ?? displayName)
            if worktreeParent != nil {
                Tag("worktree")
                    .help(nameHelp)
                    .accessibilityHidden(true)
            }
            RepoNoteView(repo: repo)
            if let projectCaption, nameIsAmbiguous, worktreeParent == nil {
                Text(projectCaption)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
            }
        }
    }

    private var nameHelp: String {
        if let parent = worktreeParent {
            return "Worktree of \(parent.name) in \(RepoNoteView.shortPath(repo.path))"
        }
        return projectCaption.map { "\(displayName) — \($0)" } ?? displayName
    }

    // MARK: Branch

    @ViewBuilder
    private var branchCell: some View {
        if let status = repo.status {
            branchButton(status.branch)
        } else if let loadError = repo.loadError {
            Label(loadError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(loadError)
        } else {
            Text("Reading status…")
                .foregroundStyle(.tertiary)
        }
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
            // Give the stack a moment to scroll the row into view before anchoring.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                showBranches = true
            }
        }
        .help("Switch Branch (⌘B)")
        .accessibilityLabel("Branch \(branch.head ?? "detached"). Change branch")
    }

    // MARK: State

    /// What the repo needs, in words, in its status colour — one fact per piece.
    @ViewBuilder
    private var stateCell: some View {
        if let status = repo.status {
            HStack(spacing: 10) {
                if let progress = repo.progressText, repo.activity != nil {
                    Text(progress)
                        .truncationMode(.tail)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                } else {
                    if status.hasChanges {
                        changesSummary(status)
                    }
                    syncSummary(status)
                    if status.stashCount > 0 {
                        stashButton(count: status.stashCount)
                    }
                }
            }
            .monospacedDigit()
        }
    }

    private func changesSummary(_ status: RepoStatus) -> some View {
        let count = status.changedPathCount
        let draft = repo.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 6) {
            Text(count == 1 ? "1 change" : "\(count.formatted()) changes")
                .foregroundStyle(repo.urgency == .dormant ? AnyShapeStyle(.secondary) : AnyShapeStyle(RepoUrgency.changes.tint))
            if isFolded, let edited = repo.lastEditedAt {
                Text(edited.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .foregroundStyle(.tertiary)
                    .help("Last edited \(edited.formatted(date: .abbreviated, time: .shortened))")
            }
            if isFolded, !draft.isEmpty {
                // Folding keeps the message; this says it's waiting.
                Tag("Draft").help(draft)
            }
        }
    }

    @ViewBuilder
    private func syncSummary(_ status: RepoStatus) -> some View {
        let help = repo.freshnessText.isEmpty ? status.syncState.description : "\(status.syncState.description) · \(repo.freshnessText)"
        Group {
            switch status.syncState {
            case .ahead(let n):
                Text("\(n.formatted()) to push").foregroundStyle(RepoUrgency.readyToPush.tint)
            case .behind(let n):
                Text("\(n.formatted()) to pull").foregroundStyle(RepoUrgency.behind.tint)
            case .diverged(let a, let b):
                HStack(spacing: 6) {
                    Text("\(a.formatted()) to push").foregroundStyle(RepoUrgency.readyToPush.tint)
                    Text("\(b.formatted()) to pull").foregroundStyle(RepoUrgency.behind.tint)
                }
            case .unpublished:
                if status.branch.hasCommits {
                    Text("Not published").foregroundStyle(repo.worktreeOf == nil ? AnyShapeStyle(RepoUrgency.unpublished.tint) : AnyShapeStyle(.tertiary))
                }
            case .upstreamGone:
                Label("Remote branch gone", systemImage: status.syncState.symbol).foregroundStyle(.orange)
            case .noRemote:
                Label("Local only", systemImage: status.syncState.symbol).foregroundStyle(.tertiary)
            case .upToDate:
                if let signIn = repo.signInHost {
                    Label("Can't fetch", systemImage: "person.badge.key").foregroundStyle(.tertiary)
                        .help("\(signIn) needs a sign-in before Ferry can fetch")
                } else if repo.isSnoozed {
                    Text("Snoozed").foregroundStyle(.tertiary)
                        .help("Out of Needs Attention until something in this repo changes")
                }
            }
        }
        .help(help)
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

    // MARK: Action

    /// Push / Pull / Sync / Publish for a repo without local changes; a repo with
    /// changes acts from its composer.
    @ViewBuilder
    private var actionCell: some View {
        if repo.status?.hasChanges == false || repo.activity != nil {
            QuietPrimaryButton(repo: repo)
                .controlSize(.small)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    // MARK: Helpers

    /// Another repo in the fleet has the same name, so the name alone doesn't say which one.
    private var nameIsAmbiguous: Bool {
        guard let app else { return false }
        let name = repo.name.lowercased()
        return app.allRepos.contains { $0.id != repo.id && $0.worktreeOf == nil && $0.name.lowercased() == name }
    }

    /// A worktree goes by its repo's name (its folder is often a tool's hash); the tag and
    /// the branch column say which one it is.
    private var displayName: String { privacy(worktreeParent?.name ?? repo.name) }

    private func privacy(_ name: String) -> String {
        app?.settings.privacyMode == true ? String(repeating: "•", count: min(name.count, 10)) : name
    }

    private var worktreeParent: RepoItem? {
        repo.worktreeOf.flatMap { app?.repos[$0] }
    }
}

/// A small grey capsule: "worktree", "Draft".
struct Tag: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .fixedSize()
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

/// Push / Pull / Sync / Publish for a repo without local changes; a ✓ right after
/// success. The row's state column carries the counts, so the label only names the act —
/// and says so when the push lands on a protected branch ("Push to main").
struct QuietPrimaryButton: View {
    var repo: RepoItem

    var body: some View {
        Group {
            if let activity = repo.activity {
                BusyLabel(text: activity.verb)
            } else {
                switch repo.primaryAction {
                case .publish:
                    Button {
                        Task { await repo.publish() }
                    } label: {
                        Label("Publish", systemImage: "icloud.and.arrow.up")
                    }
                    .help("Push this branch to \(repo.status?.hasRemote == true ? "the remote" : "a remote") and track it")
                    .accessibilityLabel("Publish Branch")
                case .sync(let a, let b):
                    Button {
                        Task { await repo.sync() }
                    } label: {
                        Label(Self.actTitle(ahead: a, behind: b, protectedBranch: protectedBranch), systemImage: Self.symbol(ahead: a, behind: b))
                    }
                    .help((b > 0 && a > 0 ? "Pull, then push" : a > 0 ? "Push" : "Pull") + (protectedBranch.map { " — \($0) is a protected branch" } ?? "") + (repo.freshnessText.isEmpty ? "" : " · \(repo.freshnessText)"))
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

    /// The branch name when this push lands on a protected branch.
    private var protectedBranch: String? {
        repo.warnsProtectedBranch ? repo.status?.branch.head : nil
    }

    static func actTitle(ahead: Int, behind: Int, protectedBranch: String?) -> String {
        let verb = ahead > 0 && behind > 0 ? "Sync" : ahead > 0 ? "Push" : "Pull"
        guard ahead > 0, let protectedBranch else { return verb }
        return "\(verb) to \(protectedBranch)"
    }

    static func symbol(ahead: Int, behind: Int) -> String {
        ahead > 0 && behind > 0 ? "arrow.triangle.2.circlepath" : ahead > 0 ? "arrow.up" : "arrow.down"
    }

    /// "Sync 2↑", for menus that show no counts elsewhere.
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
            WorktreesSubmenu(repo: repo)
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
