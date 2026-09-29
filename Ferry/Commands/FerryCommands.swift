import SwiftUI
import FerryKit

/// App menus. Repository commands act on the current repo (focused card, else the
/// last one clicked, else the first repo that needs attention).
struct FerryCommands: Commands {
    var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Folder…") { app.addFolders() }
                .keyboardShortcut("o")
            Button("Add Repository…") { app.addRepositoryManually() }
                .disabled(app.phase != .ready)
            Button("Rescan All Folders") { Task { await app.rescan() } }
                .disabled(app.phase != .ready || app.isScanning)
        }

        CommandGroup(after: .textEditing) {
            Button("Filter Repos") { app.focusSearchCount += 1 }
                .keyboardShortcut("f")
                .disabled(app.phase != .ready)
        }

        CommandGroup(after: .sidebar) {
            Button("Needs Attention") { app.selection = .attention }
                .keyboardShortcut("1")
            Button("All Repositories") { app.selection = .all }
                .keyboardShortcut("2")
            Divider()
            Button("Refresh") { Task { await app.refreshAll() } }
                .keyboardShortcut("r")
            Button(app.showsHistory ? "Hide History" : "Show History") { app.showsHistory.toggle() }
                .keyboardShortcut("h", modifiers: [.command, .option])
            Divider()
            Toggle("Hide Repo Names", isOn: Binding(get: { app.settings.privacyMode }, set: { app.settings.privacyMode = $0 }))
        }

        CommandMenu("Repository") {
            let repo = app.commandTarget
            let busy = repo?.activity != nil
            let hasChanges = repo?.status?.hasChanges ?? false
            let hasUpstream = repo?.status?.branch.upstream != nil
            let hasRemote = repo?.status?.hasRemote ?? false

            Button(commitTitle(repo)) { if let repo { app.requestCommit(repo) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(repo == nil || !hasChanges || busy)
            Button("Commit & Push") { if let repo { app.requestCommit(repo, then: .push) } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(repo == nil || !hasChanges || busy || !hasRemote)
            Button("Commit & Sync") { if let repo { app.requestCommit(repo, then: .sync) } }
                .disabled(repo == nil || !hasChanges || busy || !hasUpstream)
            Button("Amend Last Commit") { if let repo { app.requestAmend(repo) } }
                .disabled(!(repo?.lastCommitIsUnpushed ?? false) || busy)
            Button("Undo Last Commit") { if let repo { Task { await repo.undoLastCommit() } } }
                .disabled(!(repo?.lastCommitIsUnpushed ?? false) || busy)
            Divider()
            Button("Generate Message") { if let repo { app.generateMessage(for: repo) } }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(!hasChanges || busy)
            Divider()
            Button("Sync") { if let repo { Task { await repo.sync() } } }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!hasUpstream || busy)
            Button("Push") { if let repo { Task { await repo.pushOrPublish() } } }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!hasRemote || busy)
            Button("Pull") { if let repo { Task { await repo.pull() } } }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!hasUpstream || busy)
            Button("Fetch") { if let repo { Task { await repo.fetch() } } }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!hasRemote || busy)
            Button("Publish Branch") { if let repo { Task { await repo.publish() } } }
                .disabled(repo?.primaryAction != .publish || busy)
            Button("Fetch All") { Task { await app.fetchAll() } }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
            Divider()
            Button("Switch Branch…") {
                if let repo {
                    app.currentRepoID = repo.id
                    app.scrollTarget = repo.id
                    app.branchPickerRequest = repo.id
                }
            }
            .keyboardShortcut("b")
            .disabled(repo?.git == nil || busy)
            if let repo, repo.isSnoozed {
                Button("Unsnooze") { app.unsnooze(repo) }
            } else {
                Button("Snooze Until It Changes") { if let repo { app.snooze(repo) } }
                    .disabled(!(repo?.status?.needsAttention ?? false))
            }
            Button("Stash Changes") { if let repo { Task { await repo.stash() } } }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!hasChanges || busy)
            Divider()
            Button("Open in Terminal") { if let repo { Opener.openInTerminal(repo.path, bundleID: app.settings.terminalBundleID) } }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(repo == nil)
            Button("Open in Editor") { if let repo { Opener.openInEditor(repo.path, bundleID: app.settings.editorBundleID) } }
                .disabled(repo == nil)
            Button("Reveal in Finder") { if let repo { Opener.reveal(repo.path) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(repo == nil)
            Button("Copy Path") { if let repo { Opener.copy(repo.path.path) } }
                .disabled(repo == nil)
            Divider()
            let nothingNeedsYou = app.phase != .ready || app.repoNeedingYou(step: 1) == nil
            Button("Next Repo That Needs You") { app.goToRepoNeedingYou(step: 1) }
                .keyboardShortcut("]")
                .disabled(nothingNeedsYou)
            Button("Previous Repo That Needs You") { app.goToRepoNeedingYou(step: -1) }
                .keyboardShortcut("[")
                .disabled(nothingNeedsYou)
        }
    }

    private func commitTitle(_ repo: RepoItem?) -> String {
        guard let repo else { return "Commit" }
        if case .commit(let all) = repo.primaryAction, all { return "Commit All in \(repo.name)" }
        return "Commit in \(repo.name)"
    }
}
