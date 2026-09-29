import AppKit
import Observation

/// The Dock icon: a badge with the number of repos that need attention, and a Dock menu
/// that mirrors the menu bar extra (the extra may be hidden, so it is never the only way
/// to reach these).
final class DockController: NSObject {
    private let app: AppModel
    private let openMainWindow: () -> Void

    init(app: AppModel, openMainWindow: @escaping () -> Void) {
        self.app = app
        self.openMainWindow = openMainWindow
        super.init()
        updateBadge()
    }

    /// Re-reads the count whenever anything it depends on changes (statuses, projects,
    /// the setting), so the badge follows the list without polling.
    private func updateBadge() {
        let label: String? = withObservationTracking {
            guard app.settings.showDockBadge else { return nil }
            let count = app.attentionCount
            return count > 0 ? "\(count)" : nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateBadge() }
        }
        if NSApp.dockTile.badgeLabel != label {
            NSApp.dockTile.badgeLabel = label
        }
    }

    // MARK: - Dock menu

    /// Built fresh each time the Dock asks, so it always shows the current state.
    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if app.phase == .ready {
            let attention = app.allRepos.filter(\.needsAttention)
            let summary = NSMenuItem(title: app.attentionSummary(attention), action: nil, keyEquivalent: "")
            summary.isEnabled = false
            menu.addItem(summary)
            menu.addItem(.separator())
            for repo in attention {
                let item = item(repo.menuTitle, #selector(showRepo(_:)))
                item.representedObject = repo.id
                menu.addItem(item)
            }
            if !attention.isEmpty { menu.addItem(.separator()) }
            let fetch = item("Fetch All", #selector(fetchAll))
            fetch.isEnabled = !app.isFetchingAll
            menu.addItem(fetch)
        }
        menu.addItem(item("Open Ferry", #selector(openFerry)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showRepo(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let repo = app.repos[id] else { return }
        openMainWindow()
        app.showFromMenu(repo)
    }

    @objc private func fetchAll() {
        Task { await app.fetchAll() }
    }

    @objc private func openFerry() {
        openMainWindow()
    }
}
