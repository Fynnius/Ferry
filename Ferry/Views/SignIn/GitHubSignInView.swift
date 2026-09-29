import SwiftUI
import FerryKit

/// How git signs in to GitHub, loaded on demand; shared by onboarding, Settings → Git
/// and the stack's sign-in notice.
@Observable
final class GitHubConnection {
    private(set) var status: GitHubSignInStatus?
    private(set) var isConnecting = false
    private(set) var error: String?
    private var loading: Task<GitHubSignInStatus?, Never>?

    /// Reads the status once; later calls wait for the same read.
    @discardableResult
    func load(_ app: AppModel) async -> GitHubSignInStatus? {
        if let status { return status }
        if let loading { return await loading.value }
        let task = Task { await app.gitHubSignInStatus() }
        loading = task
        status = await task.value
        loading = nil
        return status
    }

    /// Check Again, after the user did something in Terminal.
    func reload(_ app: AppModel) async {
        error = nil
        status = await app.gitHubSignInStatus()
    }

    func connect(_ app: AppModel) async {
        isConnecting = true
        error = nil
        do {
            try await app.connectGitHubCLI()
        } catch {
            self.error = (error as? GitHubCLIError)?.message ?? error.localizedDescription
        }
        status = await app.gitHubSignInStatus()
        isConnecting = false
    }
}

/// Where the user stands and the one thing to do next: nothing, Connect GitHub CLI, or
/// the Terminal commands that get there.
struct GitHubSignInDetail: View {
    var connection: GitHubConnection
    /// The Connect button is the step's main action (onboarding, the notice's popover).
    var prominent = true
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            if let error = connection.error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .animation(Motion.snappy, value: connection.status)
    }

    @ViewBuilder
    private var content: some View {
        if let status = connection.status {
            if status.isReady {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.usesGitHubCLI ? "Git signs in to GitHub with the GitHub CLI" : "Git can already sign in to GitHub")
                        if !status.usesGitHubCLI, let helper = status.helper {
                            Text("Using your credential helper (\(helper)).")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                switch status.cli {
                case .signedIn(let account):
                    signedIn(account: account)
                case .signedOut:
                    instructions("The GitHub CLI is installed but not signed in. Sign in once in Terminal:", commands: ["gh auth login"])
                case .notInstalled:
                    instructions("Install the GitHub CLI and sign in once in Terminal:", commands: ["brew install gh", "gh auth login"])
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking how git signs in to GitHub…").foregroundStyle(.secondary)
            }
        }
    }

    private func signedIn(account: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You're signed in to the GitHub CLI\(account.map { " as \($0)" } ?? ""). Git can use it for GitHub too.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                connectButton
                if connection.isConnecting { ProgressView().controlSize(.small) }
            }
            Text("Runs “gh auth setup-git”: it adds the GitHub CLI as git's sign-in helper for GitHub in ~/.gitconfig, so git in Terminal signs in too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        let button = Button("Connect GitHub CLI") { Task { await connection.connect(app) } }
            .disabled(connection.isConnecting)
        if prominent {
            button.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }

    private func instructions(_ text: String, commands: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).fixedSize(horizontal: false, vertical: true)
            CommandBox(commands: commands)
            HStack(spacing: 12) {
                Button("Check Again") { Task { await connection.reload(app) } }
                if commands.contains(where: { $0.hasPrefix("brew") }) {
                    Link("Other ways to install", destination: URL(string: "https://cli.github.com")!)
                        .font(.callout)
                }
            }
        }
    }
}

/// Terminal commands to copy, one per line.
struct CommandBox: View {
    var commands: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(commands.joined(separator: "\n"))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy", systemImage: "doc.on.doc") { Opener.copy(commands.joined(separator: "\n")) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy to paste into Terminal")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One line above the stack per host whose repos can't be fetched without a sign-in —
/// never a banner per repo.
struct SignInNotices: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ForEach(app.signInGroups) { group in
            SignInNoticeRow(group: group)
        }
    }
}

private struct SignInNoticeRow: View {
    var group: AppModel.SignInGroup
    @Environment(AppModel.self) private var app
    @State private var showsGitHub = false
    @State private var connection = GitHubConnection()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "person.badge.key").foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .help(group.repos.map(\.name).sorted().joined(separator: ", "))
            Spacer(minLength: 8)
            if group.isGitHub {
                Button("Connect GitHub…") { showsGitHub = true }
                    .controlSize(.small)
                    .popover(isPresented: $showsGitHub, arrowEdge: .bottom) { popover }
            } else {
                Button("Sign In…") { Task { await app.signIn(host: group.host) } }
                    .controlSize(.small)
                    .help("Fetch \(group.repos.first?.name ?? "one repo") so git can ask for your sign-in, then the others")
            }
            Button("Dismiss", systemImage: "xmark") { app.dismissSignInNotice(host: group.host) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Hide until Ferry is opened again")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private var text: String {
        let who = group.repos.count == 1 ? "\(group.repos[0].name) can't" : "\(group.repos.count) repos can't"
        return group.isGitHub
            ? "\(who) fetch from GitHub until git can sign in."
            : "\(who) fetch from \(group.host) until you sign in."
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect GitHub").font(.headline)
            Text("GitHub doesn't accept passwords for git. Once git can sign in, Ferry fetches these repos again.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GitHubSignInDetail(connection: connection)
            if connection.status?.isReady == true {
                Button("Fetch Again") {
                    showsGitHub = false
                    Task { await app.retryAfterSignIn(host: group.host) }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .task { await connection.load(app) }
    }
}
