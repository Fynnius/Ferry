import Foundation
import Darwin
import Synchronization

/// What to run. Arguments are passed as-is — no shell is involved.
public struct SubprocessRequest: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL?
    public var stdin: Data?
    public var timeout: Duration?
    /// Called with stderr text as it arrives (progress output of fetch/push).
    public var onStderr: (@Sendable (String) -> Void)?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        timeout: Duration? = nil,
        onStderr: (@Sendable (String) -> Void)? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.stdin = stdin
        self.timeout = timeout
        self.onStderr = onStderr
    }
}

public struct SubprocessResult: Sendable {
    /// Exit status, or 128 + signal number when the process was killed by a signal.
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var cancelled: Bool

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public struct SubprocessLaunchError: Error, CustomStringConvertible {
    public var executable: String
    public var errno: Int32
    public var description: String { "Couldn't start \(executable): \(String(cString: strerror(errno)))" }
}

/// Runs a child process in its own process group so cancellation and timeouts can
/// signal everything it spawned (ssh, hooks, credential helpers), not just the child.
/// Cancel/timeout escalate SIGINT → SIGTERM → SIGKILL with a grace period, giving git
/// the chance to remove its lock files.
public enum Subprocess {
    public static let gracePeriod: Duration = .seconds(2)
    public static let lingerAfterExit: Duration = .seconds(2)

    /// Writing to a child that exited early must fail with EPIPE, not kill Ferry.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public static func run(_ request: SubprocessRequest) async throws -> SubprocessResult {
        _ = ignoreSIGPIPE
        let child = try SpawnedChild(request)
        return await withTaskCancellationHandler {
            await child.waitForExit()
        } onCancel: {
            child.terminate(reason: .cancelled)
        }
    }
}

private final class SpawnedChild: Sendable {
    enum StopReason { case cancelled, timedOut }

    private struct State {
        var exited = false
        var exitedAt: ContinuousClock.Instant?
        var cancelled = false
        var timedOut = false
    }

    let pid: pid_t
    private let state = Mutex(State())
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let stdinFD: Int32?
    private let stdinData: Data?
    private let onStderr: (@Sendable (String) -> Void)?
    private let timeout: Duration?

    init(_ request: SubprocessRequest) throws {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        var stdinPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw SubprocessLaunchError(executable: request.executable.path, errno: errno)
        }
        let hasStdin = request.stdin != nil
        if hasStdin, pipe(&stdinPipe) != 0 {
            throw SubprocessLaunchError(executable: request.executable.path, errno: errno)
        }

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if hasStdin {
            posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        if let dir = request.currentDirectory {
            posix_spawn_file_actions_addchdir(&actions, dir.path)
        }

        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = [request.executable.path] + request.arguments
        let envp = request.environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let rc = withCStringArray(argv) { cArgs in
            withCStringArray(envp) { cEnv in
                posix_spawn(&pid, request.executable.path, &actions, &attributes, cArgs, cEnv)
            }
        }

        close(stdoutPipe[1])
        close(stderrPipe[1])
        if hasStdin { close(stdinPipe[0]) }
        guard rc == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            if hasStdin { close(stdinPipe[1]) }
            throw SubprocessLaunchError(executable: request.executable.path, errno: rc)
        }

        self.pid = pid
        self.stdoutFD = stdoutPipe[0]
        self.stderrFD = stderrPipe[0]
        self.stdinFD = hasStdin ? stdinPipe[1] : nil
        self.stdinData = request.stdin
        self.onStderr = request.onStderr
        self.timeout = request.timeout
    }

    func waitForExit() async -> SubprocessResult {
        await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            let queue = DispatchQueue.global(qos: .userInitiated)
            let output = Mutex((stdout: Data(), stderr: Data(), status: Int32(0)))

            if let stdinFD, let stdinData {
                group.enter()
                queue.async {
                    let handle = FileHandle(fileDescriptor: stdinFD, closeOnDealloc: true)
                    try? handle.write(contentsOf: stdinData)
                    try? handle.close()
                    group.leave()
                }
            }

            group.enter()
            queue.async { [stdoutFD, stderrFD, onStderr] in
                let (stdout, stderr) = self.readPipes(stdoutFD: stdoutFD, stderrFD: stderrFD, onStderr: onStderr)
                output.withLock {
                    $0.stdout = stdout
                    $0.stderr = stderr
                }
                group.leave()
            }

            group.enter()
            queue.async { [pid] in
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                output.withLock { $0.status = status }
                self.state.withLock {
                    $0.exited = true
                    $0.exitedAt = .now
                }
                group.leave()
            }

            if let timeout {
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.terminate(reason: .timedOut)
                }
            }

            group.notify(queue: queue) {
                let (stdout, stderr, status) = output.withLock { ($0.stdout, $0.stderr, $0.status) }
                let flags = self.state.withLock { $0 }
                let code: Int32
                if status & 0x7f == 0 {
                    code = (status >> 8) & 0xff
                } else {
                    code = 128 + (status & 0x7f)
                }
                continuation.resume(returning: SubprocessResult(
                    exitCode: code,
                    stdout: stdout,
                    stderr: stderr,
                    timedOut: flags.timedOut,
                    cancelled: flags.cancelled
                ))
            }
        }
    }

    func terminate(reason: StopReason) {
        state.withLock { state in
            switch reason {
            case .cancelled: state.cancelled = true
            case .timedOut: state.timedOut = true
            }
        }
        let pgid = pid
        guard groupIsAlive(pgid) else { return }
        kill(-pgid, SIGINT)
        let grace = Double(Subprocess.gracePeriod.components.seconds)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            guard groupIsAlive(pgid) else { return }
            kill(-pgid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
                guard groupIsAlive(pgid) else { return }
                kill(-pgid, SIGKILL)
            }
        }
    }

    /// True while any process in the child's group still exists — including background
    /// children that outlive git itself.
    private func groupIsAlive(_ pgid: pid_t) -> Bool {
        kill(-pgid, 0) == 0 || errno == EPERM
    }

    /// Reads stdout and stderr until both close. Once the child itself has exited, waits
    /// at most `lingerAfterExit` for stragglers (e.g. an ssh ControlPersist master that
    /// inherited stderr) instead of blocking forever.
    private func readPipes(stdoutFD: Int32, stderrFD: Int32, onStderr: (@Sendable (String) -> Void)?) -> (Data, Data) {
        var fds = [pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0), pollfd(fd: stderrFD, events: Int16(POLLIN), revents: 0)]
        var collected = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while fds.contains(where: { $0.fd >= 0 }) {
            let ready = poll(&fds, nfds_t(fds.count), 200)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                if let exitedAt = state.withLock({ $0.exitedAt }), ContinuousClock.now - exitedAt > Subprocess.lingerAfterExit {
                    break
                }
                continue
            }
            for index in fds.indices where fds[index].fd >= 0 && fds[index].revents != 0 {
                let count = read(fds[index].fd, &buffer, buffer.count)
                if count > 0 {
                    let chunk = Data(buffer[0..<count])
                    collected[index].append(chunk)
                    if index == 1 { onStderr?(String(decoding: chunk, as: UTF8.self)) }
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    close(fds[index].fd)
                    fds[index].fd = -1
                }
            }
        }
        for fd in fds where fd.fd >= 0 { close(fd.fd) }
        return (collected[0], collected[1])
    }
}

private func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
