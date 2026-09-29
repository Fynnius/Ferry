import SwiftUI
import FerryKit

/// One repo: a row in its group's list. A repo with changes opens into a composer and
/// change list under its row, lined up with the name; folded, it's one line like the rest.
struct RepoSection: View {
    @Bindable var repo: RepoItem
    var projectCaption: String?
    /// One row with its change count (folded by the user, dormant, or one of many repos
    /// with changes); the chevron, →, or a click on the row opens it.
    var isCollapsed = false
    @Environment(AppModel.self) private var app: AppModel?
    @State private var showOutput = false

    var body: some View {
        let isOpen = (repo.status?.hasChanges ?? false) && !isCollapsed
        let isCurrent = app?.currentRepoID == repo.id
        VStack(alignment: .leading, spacing: 0) {
            RepoHeader(repo: repo, projectCaption: projectCaption, isFolded: isCollapsed)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Opening is safe on any click; folding only by the chevron or ←.
                    if isCollapsed { app?.setFolded(repo, false) } else { app?.currentRepoID = repo.id }
                }
            VStack(alignment: .leading, spacing: 0) {
                if let operation = repo.status?.operation {
                    OperationBanner(repo: repo, operation: operation)
                        .padding(.top, 10)
                }
                if let problem = repo.problem {
                    ProblemBanner(repo: repo, problem: problem, showOutput: $showOutput)
                        .padding(.top, 10)
                        .transition(.opacity)
                }
                if isOpen, let status = repo.status {
                    CommitComposer(repo: repo)
                        .padding(.top, 10)
                    ChangeList(repo: repo, status: status)
                        .padding(.top, 12)
                }
            }
            .padding(.leading, RepoHeader.contentInset)
        }
        .padding(.horizontal, Metrics.rowPadding)
        .padding(.vertical, isOpen ? 12 : 8)
        .background {
            if isCurrent {
                Rectangle().fill(.tint.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { app?.currentRepoID = repo.id })
        .contextMenu { RepoActionsMenuContent(repo: repo) }
        .animation(Motion.snappy, value: repo.problem)
        .sheet(isPresented: $showOutput) {
            OutputSheet(title: "Output from git — \(repo.name)", text: repo.problem?.output ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(isCollapsed ? "Folded. Press Right Arrow to open it." : "")
    }

    private var accessibilitySummary: String {
        guard let status = repo.status else { return repo.name }
        let name = repo.worktreeOf.flatMap { app?.repos[$0]?.name }.map { "Worktree of \($0)" } ?? repo.name
        var parts = [name, "on \(status.branch.head ?? "detached HEAD")"]
        if repo.urgency != .clear { parts.append(repo.urgency.title) }
        if status.hasChanges { parts.append(status.changedPathCount == 1 ? "1 change" : "\(status.changedPathCount) changes") }
        if status.syncState != .upToDate { parts.append(status.syncState.description) }
        if repo.warnsProtectedBranch { parts.append("protected branch") }
        return parts.joined(separator: ", ")
    }
}

/// Inline error with plain-language text and one or two ways forward.
struct ProblemBanner: View {
    var repo: RepoItem
    var problem: RepoProblem
    @Binding var showOutput: Bool
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        InsetBanner {
            if problem.isInfo {
                Image(systemName: "tray.full")
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: problem.isWarning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(problem.isWarning ? .orange : .red)
            }
        } message: {
            Text(problem.message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } actions: {
            ForEach(problem.fixes, id: \.self) { fix in
                Button(title(for: fix)) { run(fix) }
                    .controlSize(.small)
                    .help(help(for: fix))
            }
            Button {
                repo.dismissProblem()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Dismiss")
            .accessibilityLabel("Dismiss message")
        }
        .accessibilityElement(children: .contain)
    }

    private func title(for fix: RepoProblem.Fix) -> String {
        switch fix {
        case .sync: "Sync"
        case .publish: "Publish Branch"
        case .pull: "Pull"
        case .showOutput: "Show Output"
        case .openTerminal: "Open in Terminal"
        case .openSettings: "Open Settings"
        case .retry: "Try Again"
        case .signIn: "Sign In…"
        case .stashAndRetry(.switchTo): "Stash and Switch"
        case .stashAndRetry(.pull): "Stash and Pull"
        case .stashAndRetry(.sync): "Stash and Sync"
        case .popStash: "Pop Stash"
        }
    }

    /// Tooltip (and VoiceOver hint) for the fixes whose title alone doesn't say enough.
    private func help(for fix: RepoProblem.Fix) -> String {
        switch fix {
        case .stashAndRetry(let intent):
            let then = switch intent {
            case .switchTo(let branch): "switch to \(branch.nameWithoutRemote)"
            case .pull: "pull"
            case .sync: "sync"
            }
            return "Put your changes in the stash, then \(then). Nothing is lost: they stay in the stash until you pop them."
        case .popStash: return "Bring the stashed changes back into your working tree"
        case .signIn: return "Fetch again and let git ask for your sign-in"
        default: return ""
        }
    }

    private func run(_ fix: RepoProblem.Fix) {
        switch fix {
        case .sync: Task { await repo.sync() }
        case .publish: Task { await repo.publish() }
        case .pull: Task { await repo.pull() }
        case .showOutput: showOutput = true
        case .openTerminal: Opener.openInTerminal(repo.path, bundleID: app?.settings.terminalBundleID ?? "")
        case .openSettings: openSettings()
        case .retry:
            repo.dismissProblem()
            Task { await repo.refresh() }
        case .signIn: Task { await repo.fetch() }
        case .stashAndRetry(let intent): Task { await repo.stashAndRetry(intent) }
        case .popStash(let stash): Task { await repo.popStash(stash) }
        }
    }
}

/// A merge/rebase/cherry-pick left in progress: say so, point to the tools that resolve it.
struct OperationBanner: View {
    var repo: RepoItem
    var operation: InProgressOperation
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        InsetBanner {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
        } message: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Open in Terminal") {
                Opener.openInTerminal(repo.path, bundleID: app?.settings.terminalBundleID ?? "")
            }
            .controlSize(.small)
            Button("Open in Editor") {
                Opener.openInEditor(repo.path, bundleID: app?.settings.editorBundleID ?? "")
            }
            .controlSize(.small)
        }
    }

    private var title: String {
        switch operation {
        case .merge: "Merge in progress"
        case .rebase: "Rebase in progress"
        case .cherryPick: "Cherry-pick in progress"
        case .revert: "Revert in progress"
        case .bisect: "Bisect in progress"
        }
    }

    private var detail: String {
        let conflicts = repo.status?.conflicted.count ?? 0
        if conflicts > 0 {
            return "\(conflicts) file\(conflicts == 1 ? " has" : "s have") conflicts. Resolve them in your editor, then stage and commit here."
        }
        switch operation {
        case .merge: return "Conflicts are resolved. Commit to finish the merge."
        case .rebase: return "Continue or abort the rebase in Terminal (git rebase --continue)."
        default: return "Finish or abort it in Terminal."
        }
    }
}

/// A neutral inset inside a card: coloured icon, primary text, small actions. The actions
/// sit after the message while it has room for ~220 pt, move under it otherwise, and
/// stack when even one row of them doesn't fit.
struct InsetBanner<Icon: View, Message: View, Actions: View>: View {
    @ViewBuilder var icon: Icon
    @ViewBuilder var message: Message
    @ViewBuilder var actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon
                message.frame(idealWidth: 220, alignment: .leading)
                Spacer(minLength: 8)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon
                    message
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        actions.fixedSize()
                    }
                    VStack(alignment: .trailing, spacing: 6) {
                        actions.fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Monospaced, selectable git/hook output.
struct OutputSheet: View {
    var title: String
    var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                Text(text.isEmpty ? "No output." : text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy") { Opener.copy(text) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 280, idealHeight: 400)
    }
}
