import AppKit

/// Hands repos and files to other apps: Terminal, the user's editor, Finder.
enum Opener {
    /// Editors Ferry offers in Settings, in order; only installed ones are shown.
    static let knownEditors: [(name: String, bundleID: String)] = [
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Zed", "dev.zed.Zed"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Nova", "com.panic.Nova"),
        ("BBEdit", "com.barebones.bbedit"),
        ("TextMate", "com.macromates.TextMate"),
    ]

    static let knownTerminals: [(name: String, bundleID: String)] = [
        ("Terminal", "com.apple.Terminal"),
        ("iTerm", "com.googlecode.iterm2"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("WezTerm", "com.github.wez.wezterm"),
    ]

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func openInTerminal(_ folder: URL, bundleID: String) {
        open([folder], with: bundleID.isEmpty ? "com.apple.Terminal" : bundleID)
    }

    /// Opens in the chosen editor, or the file's default app when none is set.
    static func openInEditor(_ url: URL, bundleID: String) {
        openFile(url, editorBundleID: bundleID)
    }

    /// Extensions whose default "open" runs code (Terminal scripts, installers, apps).
    static let executableExtensions: Set<String> = ["command", "tool", "terminal", "sh", "zsh", "bash", "fish", "app", "pkg", "mpkg", "workflow", "action", "scpt", "scptd", "applescript", "jar", "dmg", "prefpane", "saver", "webloc", "inetloc", "fileloc"]

    /// Opens a file from a repo without ever running it: the chosen editor if set,
    /// otherwise the default app for documents — but anything whose default action would
    /// execute (a `.command` shipped in a cloned repo) opens as text or is revealed instead.
    static func openFile(_ url: URL, editorBundleID: String) {
        switch openAction(for: url, editorBundleID: editorBundleID) {
        case .editor: open([url], with: editorBundleID)
        case .textEdit: open([url], with: "com.apple.TextEdit")
        case .reveal: reveal(url)
        case .defaultApp: NSWorkspace.shared.open(url)
        }
    }

    enum OpenAction: Equatable { case editor, textEdit, reveal, defaultApp }

    /// How `openFile` handles a URL — pure, so it's testable without opening anything.
    static func openAction(for url: URL, editorBundleID: String, editorInstalled: (String) -> Bool = { Opener.isInstalled($0) }) -> OpenAction {
        if !editorBundleID.isEmpty, editorInstalled(editorBundleID) { return .editor }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory { return .reveal }
        let ext = url.pathExtension.lowercased()
        let isExecutable = FileManager.default.isExecutableFile(atPath: url.path)
        if executableExtensions.contains(ext) || (isExecutable && ext.isEmpty) { return .textEdit }
        return .defaultApp
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func open(_ urls: [URL], with bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            urls.forEach { NSWorkspace.shared.open($0) }
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
