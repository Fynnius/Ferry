import SwiftUI
import FerryKit

/// The menu bar extra — a menu (HIG), mirroring actions that also live in the
/// main window, never the only way to reach them.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let menu = app.attentionMenu
        Text(menu.summary)
        Divider()
        ForEach(menu.sections) { section in
            Section(section.urgency.title) {
                ForEach(section.repos) { repo in
                    repoMenu(repo, title: menu.title(for: repo))
                }
            }
        }
        if let more = menu.moreTitle {
            Button(more) {
                show(nil)
                app.selection = .attention
            }
        }
        if !menu.updates.isEmpty {
            Section(RepoUrgency.behind.title) {
                Button(menu.pullAllTitle) { Task { await app.pullAll(menu.updates) } }
            }
        }
        if !menu.sections.isEmpty || !menu.updates.isEmpty { Divider() }
        Button("Fetch All") { Task { await app.fetchAll() } }
            .disabled(app.isFetchingAll)
        Button("Open Ferry") { show(nil) }
            .keyboardShortcut("0")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Ferry") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func repoMenu(_ repo: RepoItem, title: String) -> some View {
        Menu {
            if repo.status?.hasChanges == true {
                Button("Write Message & Commit…") { show(repo) }
            }
            switch repo.primaryAction {
            case .sync(let a, let b):
                Button(QuietPrimaryButton.syncTitle(ahead: a, behind: b)) { Task { await repo.sync() } }
            case .publish:
                Button("Publish Branch") { Task { await repo.publish() } }
            default:
                EmptyView()
            }
            Divider()
            Button("Open in Terminal") { Opener.openInTerminal(repo.path, bundleID: app.settings.terminalBundleID) }
            Button("Reveal in Finder") { Opener.reveal(repo.path) }
        } label: {
            Text(title)
        }
    }

    private func show(_ repo: RepoItem?) {
        openWindow(id: "main")
        NSApp.activate()
        if let repo { app.showFromMenu(repo) }
    }
}

/// The menu bar icon: the ferry, with a dot when something needs attention.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Image(systemName: app.attentionCount > 0 ? "ferry.fill" : "ferry")
            .accessibilityLabel(app.attentionCount > 0 ? "Ferry, \(app.attentionCount) repos need attention" : "Ferry")
    }
}
