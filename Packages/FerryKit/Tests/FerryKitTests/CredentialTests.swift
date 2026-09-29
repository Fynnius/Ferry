import Foundation
import Testing
import Synchronization
@testable import FerryKit

/// Prompts, the askpass gate, credential helpers and the GitHub CLI. Real git with an
/// isolated config; `gh` is a fake script — the real one and `~/.gitconfig` are never used.
@Suite("Credentials")
struct CredentialTests {
    /// A shell script in its own temp folder, executable.
    private static func script(_ name: String, _ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-bin-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: Runner

    @Test func backgroundRunnerNeverAsks() async throws {
        let fixture = try await GitFixture.make()
        let marker = fixture.root.appendingPathComponent("asked")
        let askpass = try Self.script("askpass", "touch '\(marker.path)'; echo sekrit")
        let prompting = GitRunner(installation: fixture.runner.installation, shell: fixture.environment, askpassPath: askpass.path)
        let quiet = prompting.withoutPrompts()

        #expect(prompting.canPrompt)
        #expect(!quiet.canPrompt)
        #expect(quiet.baseEnvironment["SSH_ASKPASS"] == nil)
        #expect(quiet.baseEnvironment["SSH_ASKPASS_REQUIRE"] == "never")
        #expect(quiet.baseEnvironment["GIT_TERMINAL_PROMPT"] == "0")

        // git really doesn't run the helper without askpass, and fails instead of hanging.
        let request = Data("protocol=https\nhost=example.com\n\n".utf8)
        let failed = try await quiet.runAllowingFailure(["credential", "fill"], in: fixture.root, stdin: request)
        #expect(failed.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let answered = try await prompting.runAllowingFailure(["credential", "fill"], in: fixture.root, stdin: request)
        #expect(answered.text.contains("password=sekrit"))
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: Prompts

    @Test func parsesGitAndSSHPrompts() {
        let user = CredentialPrompt("Username for 'https://github.com': ")
        #expect(user.kind == .username)
        #expect(user.host == "github.com")
        #expect(user.isGitHub)
        #expect(user.cancelKey == "github.com")

        let password = CredentialPrompt("Password for 'https://octocat@github.com': ")
        #expect(password.kind == .password)
        #expect(password.host == "github.com")
        #expect(password.username == "octocat")

        let gitlab = CredentialPrompt("Password for 'https://me%40work.dev@gitlab.example.com': ")
        #expect(gitlab.host == "gitlab.example.com")
        #expect(gitlab.username == "me@work.dev")
        #expect(!gitlab.isGitHub)

        let passphrase = CredentialPrompt("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ")
        #expect(passphrase.kind == .passphrase)
        #expect(passphrase.host == nil)
        #expect(passphrase.cancelKey == passphrase.text)

        let ssh = CredentialPrompt("git@git.example.com's password: ")
        #expect(ssh.kind == .password)
        #expect(ssh.host == "git.example.com")

        #expect(CredentialPrompt("Are you sure you want to continue connecting (yes/no/[fingerprint])? ").kind == .other)
    }

    // MARK: Gate

    @Test func cancelSilencesTheSameHostForAMinute() throws {
        let gate = AskpassGate(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-gate-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: gate.directory) }
        let now = Date()
        #expect(!gate.wasCancelledRecently("github.com", now: now))
        gate.recordCancel("github.com", now: now)
        #expect(gate.wasCancelledRecently("github.com", now: now.addingTimeInterval(30)))
        #expect(!gate.wasCancelledRecently("github.com", now: now.addingTimeInterval(61)))
        #expect(!gate.wasCancelledRecently("gitlab.com", now: now.addingTimeInterval(30)))
        let key = "Enter passphrase for key '/Users/me/.ssh/id_ed25519': "
        gate.recordCancel(key, now: now)
        #expect(gate.wasCancelledRecently(key, now: now))

        gate.forgetCancellations()
        #expect(!gate.wasCancelledRecently("github.com", now: now))
        #expect(!gate.wasCancelledRecently(key, now: now))
    }

    @Test func oneDialogAtATime() async throws {
        let gate = AskpassGate(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ferry-gate-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: gate.directory) }
        let log = Mutex<[String]>([])
        // Separate threads, like separate askpass processes; flock is per open file, so it
        // serializes them the same way.
        await withTaskGroup(of: Void.self) { group in
            for name in ["a", "b", "c"] {
                group.addTask {
                    await withCheckedContinuation { done in
                        Thread.detachNewThread {
                            gate.withLock {
                                log.withLock { $0.append("\(name) in") }
                                Thread.sleep(forTimeInterval: 0.1)
                                log.withLock { $0.append("\(name) out") }
                            }
                            done.resume()
                        }
                    }
                }
            }
        }
        let events = log.withLock { $0 }
        #expect(events.count == 6)
        for pair in stride(from: 0, to: events.count, by: 2) {
            #expect(events[pair].hasSuffix(" in"))
            #expect(events[pair + 1] == events[pair].replacingOccurrences(of: " in", with: " out"), "no two prompts overlap: \(events)")
        }
    }

    // MARK: Helpers

    @Test func recognisesHelpersAndRemotes() {
        #expect(CredentialHelper.isGitHubCLI("!/opt/homebrew/bin/gh auth git-credential"))
        #expect(!CredentialHelper.isGitHubCLI("osxkeychain"))
        #expect(CredentialHelper.parseHelper("osxkeychain\n") == "osxkeychain")
        #expect(CredentialHelper.parseHelper("\n") == nil)

        #expect(CredentialHelper.isHTTPSGitHub("https://github.com/acme/app.git"))
        #expect(CredentialHelper.isHTTPSGitHub("https://octocat@github.com/acme/app"))
        #expect(!CredentialHelper.isHTTPSGitHub("git@github.com:acme/app.git"))
        #expect(!CredentialHelper.isHTTPSGitHub("ssh://git@github.com/acme/app.git"))
        #expect(!CredentialHelper.isHTTPSGitHub("https://gitlab.com/acme/app.git"))
    }

    @Test func readsTheHelperGitUsesForGitHub() async throws {
        let none = try await GitFixture.make()
        #expect(await CredentialHelper.effective(for: "https://github.com", runner: none.runner, in: none.root) == nil)

        let keychain = try await GitFixture.make(extraConfig: "[credential]\n    helper = osxkeychain")
        #expect(await CredentialHelper.effective(for: "https://github.com", runner: keychain.runner, in: keychain.root) == "osxkeychain")

        // What `gh auth setup-git` writes: a host-specific entry that resets the list first.
        let gh = try await GitFixture.make(extraConfig: """
        [credential]
            helper = osxkeychain
        [credential "https://github.com"]
            helper =
            helper = !/opt/homebrew/bin/gh auth git-credential
        """)
        let helper = try #require(await CredentialHelper.effective(for: "https://github.com", runner: gh.runner, in: gh.root))
        #expect(CredentialHelper.isGitHubCLI(helper))
        #expect(await CredentialHelper.effective(for: "https://gitlab.com", runner: gh.runner, in: gh.root) == "osxkeychain")
    }

    @Test func knowsWhetherGitCanSignInWithoutAsking() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-creds-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("credentials")
        try "https://x-access-token:ghp_test@github.com\n".write(to: store, atomically: true, encoding: .utf8)

        let stored = try await GitFixture.make(extraConfig: "[credential]\n    helper = store --file=\(store.path)")
        #expect(await CredentialHelper.hasStoredCredential(host: "github.com", runner: stored.runner, in: stored.root))
        #expect(await !CredentialHelper.hasStoredCredential(host: "gitlab.com", runner: stored.runner, in: stored.root))

        let empty = try await GitFixture.make()
        #expect(await !CredentialHelper.hasStoredCredential(host: "github.com", runner: empty.runner, in: empty.root))
    }

    // MARK: GitHub CLI

    private static func fakeGH() throws -> (bin: URL, log: URL) {
        let gh = try script("gh", """
        echo "$@" >> "$FAKE_GH_LOG"
        case "$1 $2" in
          "auth token") [ -n "$FAKE_GH_TOKEN" ] && { echo "$FAKE_GH_TOKEN"; exit 0; }; echo "no oauth token found for github.com" >&2; exit 1;;
          "config get") echo "octocat";;
          "auth setup-git") [ -n "$FAKE_GH_TOKEN" ] && exit 0; echo "You are not logged into any GitHub hosts." >&2; exit 1;;
          *) exit 1;;
        esac
        """)
        return (gh.deletingLastPathComponent(), gh.deletingLastPathComponent().appendingPathComponent("calls.log"))
    }

    @Test func detectsTheGitHubCLI() async throws {
        #expect(await GitHubCLI.state(environment: ["PATH": "/usr/bin:/bin"]) == .notInstalled)

        let (bin, log) = try Self.fakeGH()
        let path = "\(bin.path):/usr/bin:/bin"
        #expect(await GitHubCLI.state(environment: ["PATH": path, "FAKE_GH_LOG": log.path]) == .signedOut)
        let signedIn = ["PATH": path, "FAKE_GH_LOG": log.path, "FAKE_GH_TOKEN": "gho_test"]
        #expect(await GitHubCLI.state(environment: signedIn) == .signedIn(account: "octocat"))
        #expect(await GitHubCLI(environment: signedIn)?.token() == "gho_test")
    }

    @Test func connectRunsSetupGitForGitHubOnly() async throws {
        let (bin, log) = try Self.fakeGH()
        let path = "\(bin.path):/usr/bin:/bin"
        let signedIn = try #require(GitHubCLI(environment: ["PATH": path, "FAKE_GH_LOG": log.path, "FAKE_GH_TOKEN": "gho_test"]))
        try await signedIn.setUpGit()
        let calls = try String(contentsOf: log, encoding: .utf8)
        #expect(calls.contains("auth setup-git --hostname github.com"))

        let signedOut = try #require(GitHubCLI(environment: ["PATH": path, "FAKE_GH_LOG": log.path]))
        await #expect(throws: GitHubCLIError(message: "You are not logged into any GitHub hosts.")) {
            try await signedOut.setUpGit()
        }
    }

    @Test func statusCombinesCLIHelperAndCredential() async throws {
        let (bin, log) = try Self.fakeGH()
        let fixture = try await GitFixture.make()
        var variables = fixture.environment.variables
        variables["PATH"] = "\(bin.path):/usr/bin:/bin"
        variables["FAKE_GH_LOG"] = log.path
        variables["FAKE_GH_TOKEN"] = "gho_test"
        let runner = GitRunner(installation: fixture.runner.installation, shell: ShellEnvironment(variables: variables, source: .fallback(reason: "tests")))
        let status = await GitHubSignInStatus.read(runner: runner, in: fixture.root)
        #expect(status.cli == .signedIn(account: "octocat"))
        #expect(status.helper == nil)
        #expect(!status.isReady)
    }
}
