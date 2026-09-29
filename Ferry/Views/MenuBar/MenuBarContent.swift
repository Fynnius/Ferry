import SwiftUI
import FerryKit

/// The menu bar extra — a menu (HIG), mirroring actions that also live in the
/// main window, never the only way to reach them.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let attention = app.allRepos.filter(\.needsAttention)
        Text(app.attentionSummary(attention))
        Divider()
        ForEach(attention) { repo in
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
                Text(repo.menuTitle)
            }
        }
        if !attention.isEmpty { Divider() }
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
