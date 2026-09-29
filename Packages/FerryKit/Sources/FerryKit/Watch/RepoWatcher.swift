import Foundation
import CoreServices
import Synchronization

/// FSEventStreamRef isn't Sendable; every access goes through the watcher's mutex.
private struct StreamBox: @unchecked Sendable {
    let ref: FSEventStreamRef
}

/// A repo to watch: its working tree, and its git dir when that lives elsewhere
/// (worktrees keep theirs inside the main repo's `.git/worktrees/`).
public struct WatchedRepo: Hashable, Sendable {
    public var id: String
    public var root: URL
    public var gitDirectory: URL?

    public init(id: String, root: URL, gitDirectory: URL? = nil) {
        self.id = id
        self.root = root
        self.gitDirectory = gitDirectory
    }
}

/// Watches every repo with one FSEvents stream and reports which repos changed,
/// debounced per repo, so Ferry refreshes only what changed and idles at ~0% CPU.
public final class RepoWatcher: Sendable {
    public typealias Handler = @Sendable (Set<String>) -> Void

    private struct State {
        var repos: [WatchedRepo] = []
        var stream: StreamBox?
        var pending: Set<String> = []
        var flushScheduled = false
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "ferry.repo-watcher", qos: .utility)
    private let debounce: Duration
    private let handler: Handler

    public init(debounce: Duration = .milliseconds(150), onChange handler: @escaping Handler) {
        self.debounce = debounce
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Replaces the watched set. Cheap to call whenever the repo list changes.
    public func watch(_ repos: [WatchedRepo]) {
        stop()
        guard !repos.isEmpty else { return }
        // FSEvents reports real paths (/private/var…, symlinks resolved); match on those.
        let repos = repos.map { repo in
            WatchedRepo(id: repo.id, root: Self.canonical(repo.root), gitDirectory: repo.gitDirectory.map(Self.canonical))
        }
        let paths = repos.flatMap { repo -> [String] in
            var paths = [repo.root.path]
            if let dir = repo.gitDirectory, !dir.path.hasPrefix(repo.root.path + "/") { paths.append(dir.path) }
            return paths
        }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.received(Array(array.prefix(count)))
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        let box = StreamBox(ref: stream)
        state.withLock {
            $0.repos = repos
            $0.stream = box
        }
    }

    public func stop() {
        let box = state.withLock { state -> StreamBox? in
            let box = state.stream
            state.stream = nil
            state.repos = []
            return box
        }
        if let stream = box?.ref {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func received(_ paths: [String]) {
        let shouldSchedule = state.withLock { state -> Bool in
            for path in paths {
                if let id = Self.repo(for: path, in: state.repos) { state.pending.insert(id) }
            }
            guard !state.pending.isEmpty, !state.flushScheduled else { return false }
            state.flushScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        let seconds = Double(debounce.components.seconds) + Double(debounce.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            let ids = self.state.withLock { state -> Set<String> in
                let ids = state.pending
                state.pending = []
                state.flushScheduled = false
                return ids
            }
            if !ids.isEmpty { self.handler(ids) }
        }
    }

    /// Directories whose churn never changes what Ferry shows: git's object store and
    /// logs, and build/dependency output that projects virtually always ignore.
    static let ignoredComponents: Set<String> = [
        "node_modules", ".build", "DerivedData", ".next", ".nuxt", ".turbo", ".cache", ".parcel-cache",
        ".gradle", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", "target", ".svelte-kit",
    ]

    static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// The repo an event path belongs to, or nil when the event is noise.
    static func repo(for rawPath: String, in repos: [WatchedRepo]) -> String? {
        let path = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        // The deepest matching root wins, so a nested repo gets its own events.
        var best: (id: String, length: Int, relative: Substring, isGitDir: Bool)?
        for repo in repos {
            for (base, isGitDir) in [(repo.root.path, false), (repo.gitDirectory?.path, true)] {
                guard let base else { continue }
                let relative: Substring
                if path == base {
                    relative = ""
                } else if path.hasPrefix(base + "/") {
                    relative = path.dropFirst(base.count + 1)
                } else {
                    continue
                }
                if best == nil || base.count > best!.length {
                    best = (repo.id, base.count, relative, isGitDir)
                }
            }
        }
        guard let best else { return nil }

        var components = best.relative.split(separator: "/").map(String.init)
        if !best.isGitDir, components.first == ".git" {
            components.removeFirst()
            return isRelevantGitPath(components) ? best.id : nil
        }
        if best.isGitDir {
            return isRelevantGitPath(components) ? best.id : nil
        }
        if components.contains(where: ignoredComponents.contains) { return nil }
        return best.id
    }

    /// Inside `.git`: HEAD, index, refs, FETCH_HEAD and operation markers matter;
    /// objects, logs and hooks don't.
    private static func isRelevantGitPath(_ components: [String]) -> Bool {
        guard let first = components.first else { return true }
        return !["objects", "logs", "hooks", "info", "lfs", "modules", "fsmonitor--daemon"].contains(first)
    }
}
