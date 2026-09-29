import Foundation
import Testing
@testable import FerryKit

@Suite("Subprocess and environment")
struct SubprocessTests {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    @Test func capturesOutputAndExitCode() async throws {
        let result = try await Subprocess.run(SubprocessRequest(executable: sh, arguments: ["-c", "echo out; echo err >&2; exit 3"]))
        #expect(result.stdoutString == "out\n")
        #expect(result.stderrString == "err\n")
        #expect(result.exitCode == 3)
    }

    @Test func passesStdinAndEnvironment() async throws {
        let result = try await Subprocess.run(SubprocessRequest(
            executable: sh,
            arguments: ["-c", "cat; printf %s \"$FERRY_X\""],
            environment: ["FERRY_X": "yes"],
            stdin: Data("hello ".utf8)
        ))
        #expect(result.stdoutString == "hello yes")
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let result = try await Subprocess.run(SubprocessRequest(executable: sh, arguments: ["-c", "head -c 3000000 /dev/zero; head -c 3000000 /dev/zero >&2"]))
        #expect(result.stdout.count == 3_000_000)
        #expect(result.stderr.count == 3_000_000)
    }

    @Test func timeoutStopsTheWholeProcessGroup() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        // The grandchild `sleep` would keep the pipe open if only `sh` were signalled.
        let result = try await Subprocess.run(SubprocessRequest(
            executable: sh,
            arguments: ["-c", "sleep 30 & wait"],
            timeout: .milliseconds(300)
        ))
        #expect(result.timedOut)
        #expect(clock.now - start < .seconds(5))
    }

    @Test func cancellationStopsTheProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await Subprocess.run(SubprocessRequest(executable: sh, arguments: ["-c", "sleep 30"]))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = try await task.value
        #expect(result.cancelled)
        #expect(clock.now - start < .seconds(5))
    }

    @Test func launchFailureThrows() async {
        await #expect(throws: SubprocessLaunchError.self) {
            try await Subprocess.run(SubprocessRequest(executable: URL(fileURLWithPath: "/nonexistent/tool")))
        }
    }

    @Test func shellEnvironmentParsingIgnoresNoise() {
        let marker = "__M__"
        let payload = "Last login: today\nWelcome!\(marker)PATH=/a:/b\0HOME=/Users/x\0MULTI=line1\nline2\0\(marker)trailing"
        let vars = ShellEnvironment.parse(Data(payload.utf8), marker: marker)
        #expect(vars?["PATH"] == "/a:/b")
        #expect(vars?["MULTI"] == "line1\nline2")
        #expect(vars?["HOME"] == "/Users/x")
    }

    @Test func fallbackKeepsKnownToolDirectories() {
        let env = ShellEnvironment.fallback(base: ["PATH": "/usr/bin:/custom"], reason: "test")
        #expect(env.path.hasPrefix("/opt/homebrew/bin:/usr/local/bin"))
        #expect(env.path.contains("/custom"))
    }

    @Test func resolvesTheRealLoginShell() async {
        let env = await ShellEnvironment.resolve(timeout: .seconds(15))
        #expect(env.variables["PATH"] != nil)
    }

    @Test func versionParsing() {
        #expect(GitVersion(parsing: "git version 2.51.2") == GitVersion(2, 51, 2))
        #expect(GitVersion(parsing: "git version 2.54.0 (Apple Git-157)") == GitVersion(2, 54, 0))
        #expect(GitVersion(parsing: "git version 2.39") == GitVersion(2, 39, 0))
        #expect(GitVersion(2, 24) < GitVersion.minimumSupported)
    }
}

@Suite("Git error classification")
struct GitErrorTests {
    private func kind(_ sub: String, _ stderr: String) -> GitError.Kind {
        GitError.classify(subcommand: sub, stderr: stderr, stdout: "", exitCode: 1)
    }

    @Test func classifiesCommonFailures() {
        #expect(kind("add", "fatal: Unable to create '/r/.git/index.lock': File exists.\n\nAnother git process seems to be running") == .indexLocked)
        #expect(kind("push", "fatal: could not read Username for 'https://github.com': terminal prompts disabled") == .authenticationRequired)
        #expect(kind("fetch", "git@github.com: Permission denied (publickey).\r\nfatal: Could not read from remote repository.") == .sshKeyRejected)
        #expect(kind("fetch", "Host key verification failed.\nfatal: Could not read from remote repository.") == .hostKeyVerificationFailed)
        #expect(kind("commit", "error: gpg failed to sign the data\nfatal: failed to write commit object") == .signingFailed)
        #expect(kind("fetch", "ssh: connect to host github.com port 22: Operation timed out") == .network)
        #expect(kind("fetch", "fatal: unable to access 'https://github.com/a/b.git/': Could not resolve host: github.com") == .network)
        #expect(kind("switch", "fatal: 'topic' is already used by worktree at '/tmp/wt'") == .branchCheckedOutElsewhere)
        #expect(kind("switch", "error: Your local changes to the following files would be overwritten by checkout:") == .localChangesWouldBeOverwritten)
        #expect(kind("branch", "error: the branch 'x' is not fully merged.") == .branchNotFullyMerged)
        #expect(kind("push", " ! [remote rejected] main -> main (protected branch hook declined)\nerror: failed to push some refs") == .pushRejectedByRemote(reason: "protected branch hook declined"))
        #expect(kind("push", " ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs") == .pushRejectedBehind)
        #expect(kind("commit", "husky - pre-commit script failed (code 1)") == .hookFailed)
    }

    @Test func summariesNameTheHost() {
        let error = GitError(kind: .network, command: ["fetch"], exitCode: 128, stderr: "ssh: connect to host gitlab.example.com port 22: Operation timed out")
        #expect(error.summary.contains("gitlab.example.com"))
        let unknown = GitError(kind: .unknown, command: ["x"], exitCode: 1, stderr: "hint: ignore me\nfatal: something odd happened")
        #expect(unknown.summary == "Something odd happened")
    }
}
