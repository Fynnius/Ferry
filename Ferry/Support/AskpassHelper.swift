import AppKit

/// Ferry's own executable doubles as `GIT_ASKPASS`: when git needs a username or
/// password it runs Ferry with the prompt as its argument, and instead of starting the
/// app we show a native dialog and print the answer for git. The answer only
/// travels through git's pipe; Ferry never stores it — the user's credential helper does.
enum AskpassHelper {
    static let modeVariable = "FERRY_ASKPASS"

    /// Path git should call. Git passes the prompt as argv[1].
    static var path: String? {
        Bundle.main.executablePath
    }

    /// True when this process was launched by git as the askpass program.
    static var isAskpassInvocation: Bool {
        ProcessInfo.processInfo.environment[modeVariable] == "1" && CommandLine.arguments.count >= 2
    }

    /// macOS only lets another process come forward if the active app yields. Called by
    /// the main app before network operations, so a credential prompt gets focus.
    static func allowPromptActivation() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: id)
    }

    /// Shows the prompt and exits: 0 with the answer on stdout, 1 when cancelled.
    static func runAndExit() -> Never {
        let prompt = CommandLine.arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Registers with the window server and Accessibility (VoiceOver) — runModal alone doesn't.
        app.finishLaunching()
        app.activate()

        let secret = prompt.localizedCaseInsensitiveContains("password")
            || prompt.localizedCaseInsensitiveContains("passphrase")
            || prompt.localizedCaseInsensitiveContains("token")
        let alert = NSAlert()
        alert.messageText = secret ? "Git needs a password" : "Git needs a sign-in"
        alert.informativeText = prompt.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            + "\n\nFerry passes this to git only. Your credential helper decides whether it's saved."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let field: NSTextField = secret ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = secret ? "Password or token" : "Username"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.window.level = .modalPanel
        alert.window.makeKeyAndOrderFront(nil)
        app.activate()

        guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
        FileHandle.standardOutput.write(Data((field.stringValue + "\n").utf8))
        exit(0)
    }
}
