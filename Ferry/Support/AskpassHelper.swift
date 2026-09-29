import AppKit
import FerryKit

/// Ferry's own executable doubles as `GIT_ASKPASS`: when git needs a username or
/// password it runs Ferry with the prompt as its argument, and instead of starting the
/// app we show a native dialog and print the answer for git. The answer only
/// travels through git's pipe; Ferry never stores it — the user's credential helper does.
///
/// Only operations the user started can get here: background fetches run without
/// askpass. Prompts wait for each other (`AskpassGate`), a cancel silences the same host
/// for a minute, and GitHub is never asked for a password it would refuse.
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
    /// `forgetCancelled`: the user asked for this one, so an earlier cancel doesn't apply.
    static func allowPromptActivation(forgetCancelled: Bool = false) {
        if forgetCancelled { AskpassGate().forgetCancellations() }
        guard let id = Bundle.main.bundleIdentifier else { return }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: id)
    }

    /// Answers the prompt and exits: 0 with the answer on stdout, 1 when cancelled.
    static func runAndExit() -> Never {
        let prompt = CredentialPrompt(CommandLine.arguments[1])
        let gate = AskpassGate()
        let answer: String? = gate.withLock {
            guard !gate.wasCancelledRecently(prompt.cancelKey) else { return nil }
            let answer = self.answer(prompt)
            if answer == nil { gate.recordCancel(prompt.cancelKey) }
            return answer
        }
        guard let answer else { exit(1) }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        exit(0)
    }

    private static func answer(_ prompt: CredentialPrompt) -> String? {
        guard prompt.isGitHub else { return ask(prompt) }
        let cli = GitHubCLI(environment: ProcessInfo.processInfo.environment)
        let state = cli.map { cli in wait { await cli.state() } } ?? .notInstalled
        switch prompt.kind {
        case .username:
            // GitHub only checks the token; git asks for it next, and that's where the
            // dialog is. gh's own helper answers with the login or `x-access-token` too.
            if case .signedIn(let account?) = state { return account }
            return "x-access-token"
        case .password:
            guard let cli, case .signedIn(let account) = state else { return askForGitHubToken(cliInstalled: cli != nil) }
            // Already git's helper (queued behind a Connect, or gh moved): answer from gh.
            if wait({ await gitUsesGitHubCLI() }) { return wait { await cli.token() } }
            return connectGitHubCLI(cli, account: account)
        case .passphrase, .other:
            return ask(prompt)
        }
    }

    // MARK: - GitHub

    /// gh is signed in: offer to make it git's helper for GitHub, then answer with its token.
    private static func connectGitHubCLI(_ cli: GitHubCLI, account: String?) -> String? {
        let alert = makeAlert(
            title: "Use the GitHub CLI to sign in?",
            message: "\(needsSignIn)GitHub doesn't accept passwords for git, but you're signed in to the GitHub CLI\(account.map { " as \($0)" } ?? "").\n\n"
                + "Connecting runs “gh auth setup-git”: it adds the GitHub CLI as git's sign-in helper for GitHub in ~/.gitconfig, so git in Terminal signs in too."
        )
        alert.addButton(withTitle: "Connect GitHub CLI")
        alert.addButton(withTitle: "Cancel")
        guard present(alert) == .alertFirstButtonReturn else { return nil }

        let failure: String? = wait {
            do {
                try await cli.setUpGit()
                return nil
            } catch {
                return (error as? GitHubCLIError)?.message ?? error.localizedDescription
            }
        }
        if let failure {
            let error = makeAlert(title: "Couldn't connect the GitHub CLI", message: failure)
            error.alertStyle = .warning
            error.addButton(withTitle: "OK")
            _ = present(error)
            return nil
        }
        return wait { await cli.token() }
    }

    /// No usable gh: explain the token and how to get gh, take a token if the user has one.
    private static func askForGitHubToken(cliInstalled: Bool) -> String? {
        let commands = (cliInstalled ? [] : ["brew install gh"]) + ["gh auth login", "gh auth setup-git"]
        let alert = makeAlert(
            title: "Sign in to GitHub",
            message: "\(needsSignIn)GitHub doesn't accept passwords for git — it needs a token. The easiest way is the GitHub CLI: run these in Terminal, then try again. Or paste a personal access token."
        )
        alert.addButton(withTitle: "Use Token")
        alert.addButton(withTitle: "Cancel")

        let actions = AlertActions(commands: commands.joined(separator: "\n"))
        let commandText = NSTextField(wrappingLabelWithString: actions.commands)
        commandText.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        commandText.isSelectable = true
        let copy = NSButton(title: "Copy Commands", target: actions, action: #selector(AlertActions.copyCommands))
        copy.controlSize = .small
        let label = NSTextField(labelWithString: "Token")
        let field = NSSecureTextField()
        field.placeholderString = "ghp_… or github_pat_…"
        let link = NSButton(title: "Create a token on GitHub…", target: actions, action: #selector(AlertActions.openTokenSettings))
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.controlSize = .small

        let stack = NSStackView(views: [commandText, copy, label, field, link])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: copy)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        commandText.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        let response = withExtendedLifetime(actions) { present(alert) }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn, !token.isEmpty else { return nil }
        return token
    }

    /// Whether git's helper for github.com already is gh. Nonisolated: `wait` blocks the
    /// main thread while this runs.
    nonisolated private static func gitUsesGitHubCLI() async -> Bool {
        // Git puts its own exec path first on PATH, so this finds the git that asked.
        let shell = ShellEnvironment(variables: ProcessInfo.processInfo.environment, source: .loginShell("askpass"))
        guard let installation = try? await GitLocator.locate(configuredPath: nil, environment: shell) else { return false }
        let runner = GitRunner(installation: installation, shell: shell)
        let helper = await CredentialHelper.effective(for: "https://\(GitHubCLI.host)", runner: runner, in: workingDirectory)
        return helper.map(CredentialHelper.isGitHubCLI) ?? false
    }

    // MARK: - Any other host

    private static func ask(_ prompt: CredentialPrompt) -> String? {
        let host = prompt.host ?? "the server"
        let alert: NSAlert
        let field: NSTextField
        switch prompt.kind {
        case .username:
            alert = makeAlert(title: "Sign in to \(host)", message: "\(needsSignIn)Enter your username for \(host).")
            field = NSTextField()
            field.placeholderString = "Username"
        case .password:
            let who = prompt.username.map { "\($0) on \(host)" } ?? host
            alert = makeAlert(title: "Sign in to \(host)", message: "\(needsSignIn)Enter the password or token for \(who).\n\nFerry passes it to git only. Your credential helper decides whether it's saved.")
            field = NSSecureTextField()
            field.placeholderString = "Password or token"
        case .passphrase:
            alert = makeAlert(title: "Unlock your SSH key", message: cleaned(prompt.text))
            field = NSSecureTextField()
            field.placeholderString = "Passphrase"
        case .other:
            alert = makeAlert(title: "Git needs an answer", message: cleaned(prompt.text))
            field = NSTextField()
        }
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard present(alert) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // MARK: - Plumbing

    /// Git runs askpass in the repo's top-level folder.
    nonisolated private static var workingDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// "“harbor-web” needs a sign-in. " — which repo is asking, when git says.
    private static var needsSignIn: String {
        let name = workingDirectory.lastPathComponent
        return name.isEmpty || name == "/" ? "" : "“\(name)” needs a sign-in. "
    }

    private static func cleaned(_ prompt: String) -> String {
        prompt.trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespacesAndNewlines))
    }

    private static func makeAlert(title: String, message: String) -> NSAlert {
        let app = NSApplication.shared
        if app.activationPolicy() != .accessory {
            app.setActivationPolicy(.accessory)
            // Registers with the window server and Accessibility (VoiceOver) — runModal alone doesn't.
            app.finishLaunching()
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        return alert
    }

    private static func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        alert.window.level = .modalPanel
        alert.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return alert.runModal()
    }

    /// Runs async FerryKit work from this synchronous, pre-app process. The main thread
    /// just waits, so `operation` must never need the main actor.
    private static func wait<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await operation()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}

nonisolated private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// Targets for the buttons inside the GitHub token alert.
private final class AlertActions: NSObject {
    let commands: String

    init(commands: String) {
        self.commands = commands
    }

    @objc func copyCommands() {
        Opener.copy(commands)
    }

    @objc func openTokenSettings() {
        NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens")!)
    }
}
