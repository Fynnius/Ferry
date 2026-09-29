import AppKit
import SwiftUI

/// Keeps Ferry alive after its window closes when the menu bar extra is on, so the
/// menu and background fetch keep working; otherwise closing the window quits, like
/// other single-window utilities. Also the AppKit end of the Dock icon (badge, menu,
/// folders dropped on it) and Finder's Open in Ferry service.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var keepsRunningWithoutWindows: () -> Bool = { false }

    private var app: AppModel?
    private var openMainWindow: () -> Void = {}
    private var dock: DockController?
    /// Folders that arrive before the main window has connected the model (e.g. Ferry
    /// launched by dropping a folder on its icon).
    private var pendingFolders: [URL] = []

    /// Called once the main window is up; SwiftUI owns the model and window opening.
    func connect(_ app: AppModel, openMainWindow: @escaping () -> Void) {
        guard self.app == nil else { return }
        self.app = app
        self.openMainWindow = openMainWindow
        dock = DockController(app: app, openMainWindow: openMainWindow)
        if !pendingFolders.isEmpty {
            open(pendingFolders)
            pendingFolders = []
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !keepsRunningWithoutWindows()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dock?.menu()
    }

    /// Folders dropped on the Dock icon, or `open -a Ferry <folder>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    /// NSServices "Open in Ferry" (see Ferry-Info.plist): Finder sends the selected folders.
    @objc func openInFerry(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        open(urls)
    }

    private func open(_ urls: [URL]) {
        guard let app else {
            pendingFolders += urls
            return
        }
        if app.openFolders(urls) {
            openMainWindow()
        }
    }
}

/// Hands the model and a way to open the main window to the delegate, from the one place
/// that has both: a view in the main window.
struct ConnectsAppDelegate: ViewModifier {
    let delegate: AppDelegate
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.connect(app) { [openWindow] in
                openWindow(id: "main")
                NSApp.activate()
            }
        }
    }
}
