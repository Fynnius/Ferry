import SwiftUI
import FerryKit

/// Message field, the AI sparkle and the Commit split button (its menu holds commit & push,
/// commit & sync, amend and undo last commit). One row; the field drops onto its own line
/// only when it would get narrower than 170 pt.
struct CommitComposer: View {
    @Bindable var repo: RepoItem
    @FocusState private var focused: Bool
    @Environment(AppModel.self) private var app: AppModel?
    @State private var showEmptyHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 8) {
                    field
                        .frame(minWidth: 170, idealWidth: 170, maxWidth: .infinity)
                    AIMessageButton(repo: repo)
                    CommitButton(repo: repo)
                }
                VStack(alignment: .leading, spacing: 8) {
                    field
                    HStack(spacing: 8) {
                        AIMessageButton(repo: repo)
                        Spacer(minLength: 8)
                        CommitButton(repo: repo, allowsShortTitle: true)
                    }
                }
            }
            // The only signal besides the shake, so it's also what Reduce Motion users see.
            if showEmptyHint {
                Text("Write a message first")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused { app?.currentRepoID = repo.id }
        }
        .onChange(of: repo.focusMessageCount) {
            focused = true
        }
        .onChange(of: repo.shakeCount) {
            Motion.animate { showEmptyHint = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                Motion.animate { showEmptyHint = false }
            }
        }
    }

    private var field: some View {
        TextField("Commit message", text: $repo.message, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...8)
            .focused($focused)
            .shake(trigger: repo.shakeCount)
            .accessibilityLabel("Commit message for \(repo.name)")
    }
}

/// The commit split button: a click commits, its menu holds the variants. While the repo
/// is busy it stays in place, disabled, showing what's running.
struct CommitButton: View {
    var repo: RepoItem
    /// Lets the title drop " to <branch>" when even the stacked layout can't fit it.
    var allowsShortTitle = false
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        HStack(spacing: 6) {
            if let activity = repo.activity {
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true)
                control(activity.verb)
            } else if case .commit(let all) = repo.primaryAction {
                let base = all ? "Commit All" : "Commit"
                if repo.warnsProtectedBranch, let branch = repo.status?.branch.head {
                    if allowsShortTitle {
                        ViewThatFits(in: .horizontal) {
                            control("\(base) to \(branch)")
                            control(base)
                        }
                    } else {
                        control("\(base) to \(branch)")
                    }
                } else {
                    control(base)
                }
            }
        }
        .animation(Motion.snappy, value: repo.activity)
    }

    private func control(_ title: String) -> some View {
        Menu {
            Button("Commit & Push") { app?.requestCommit(repo, then: .push) }
            Button("Commit & Sync") { app?.requestCommit(repo, then: .sync) }
            Divider()
            Button("Amend Last Commit") { app?.requestAmend(repo) }
                .disabled(!repo.lastCommitIsUnpushed)
            Button("Undo Last Commit") { Task { await repo.undoLastCommit() } }
                .disabled(!repo.lastCommitIsUnpushed)
        } label: {
            Text(title)
        } primaryAction: {
            app?.requestCommit(repo, then: .nothing)
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(repo.activity != nil)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint("\(help). More commit options are in its menu.")
    }

    private var help: String {
        let target = repo.status?.branch.head.map { " to \($0)" } ?? ""
        return if case .commit(all: true) = repo.primaryAction {
            "Nothing is staged, so every change will be committed\(target) (⌘↩)"
        } else {
            "Commit the staged changes\(target) (⌘↩)"
        }
    }
}
