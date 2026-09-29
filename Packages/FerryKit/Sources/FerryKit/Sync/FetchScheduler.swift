import Foundation
import Network
import Synchronization

/// How a background fetch ended, as far as scheduling cares.
public enum FetchOutcome: Sendable, Equatable {
    case success
    /// Offline, DNS, VPN: try again at the normal pace once the network is back.
    case network
    /// Credentials or host key: retrying won't help until the user acts, so back off hard.
    case authentication
    case failed
}

/// When each repo is fetched next: every `interval` (3 min, like VS Code),
/// jittered so 60 repos don't hit their remotes together, with exponential backoff
/// after failures — steep for auth failures, which need the user.
public struct FetchPolicy: Sendable, Equatable {
    public var interval: Duration
    public var jitter: Double
    public var maxBackoff: Duration

    public init(interval: Duration = .seconds(180), jitter: Double = 0.15, maxBackoff: Duration = .seconds(3600)) {
        self.interval = interval
        self.jitter = jitter
        self.maxBackoff = maxBackoff
    }

    /// Seconds until the next fetch after an outcome, given how many failures in a row.
    public func delay(after outcome: FetchOutcome, consecutiveFailures: Int, random: Double) -> TimeInterval {
        let base = interval.seconds
        let factor: Double
        switch outcome {
        case .success, .network: factor = 1
        case .failed: factor = pow(2, Double(min(consecutiveFailures, 6)))
        case .authentication: factor = pow(4, Double(min(consecutiveFailures, 4)))
        }
        let delay = min(base * factor, max(maxBackoff.seconds, base))
        return delay * (1 + jitter * (random * 2 - 1))
    }

    /// Initial offset for a newly added repo, spread over one interval.
    public func initialDelay(random: Double) -> TimeInterval {
        interval.seconds * random
    }
}

/// Drives background fetches. The decision logic (`due`, `record`) is synchronous and
/// deterministic for tests; `start` wraps it in a timer loop.
public actor FetchScheduler {
    public typealias Fetch = @Sendable (String) async -> FetchOutcome

    private struct Entry {
        var next: Date
        var failures: Int
        var lastOutcome: FetchOutcome?
    }

    public private(set) var policy: FetchPolicy
    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private var loop: Task<Void, Never>?
    private let fetch: Fetch
    private let canFetch: @Sendable () -> Bool
    private let random: @Sendable () -> Double

    public init(
        policy: FetchPolicy = FetchPolicy(),
        canFetch: @escaping @Sendable () -> Bool = { true },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        fetch: @escaping Fetch
    ) {
        self.policy = policy
        self.canFetch = canFetch
        self.random = random
        self.fetch = fetch
    }

    public func setPolicy(_ policy: FetchPolicy) {
        self.policy = policy
    }

    /// Sets the repos to fetch (those with a remote). New repos are staggered over one interval.
    public func update(repoIDs: some Sequence<String>, now: Date = .now) {
        let ids = Set(repoIDs)
        entries = entries.filter { ids.contains($0.key) }
        for id in ids where entries[id] == nil {
            entries[id] = Entry(next: now.addingTimeInterval(policy.initialDelay(random: random())), failures: 0)
        }
    }

    /// Repos whose next fetch is due and that aren't being fetched already.
    public func due(now: Date = .now) -> [String] {
        entries.filter { $0.value.next <= now && !inFlight.contains($0.key) }
            .sorted { $0.value.next < $1.value.next }
            .map(\.key)
    }

    public func record(_ outcome: FetchOutcome, for id: String, now: Date = .now) {
        guard var entry = entries[id] else { return }
        switch outcome {
        case .success, .network: entry.failures = 0
        case .failed, .authentication: entry.failures += 1
        }
        entry.lastOutcome = outcome
        entry.next = now.addingTimeInterval(policy.delay(after: outcome, consecutiveFailures: entry.failures, random: random()))
        entries[id] = entry
    }

    /// Marks a repo as just fetched by the user, resetting any backoff.
    public func fetchedManually(_ id: String, now: Date = .now) {
        record(.success, for: id, now: now)
    }

    public func nextDate(for id: String) -> Date? {
        entries[id]?.next
    }

    public func start(tick: Duration = .seconds(15)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runDue()
                try? await Task.sleep(for: tick)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    private func runDue() async {
        guard canFetch() else { return }
        let ids = due()
        guard !ids.isEmpty else { return }
        inFlight.formUnion(ids)
        await withTaskGroup(of: (String, FetchOutcome).self) { group in
            for id in ids {
                group.addTask { [fetch] in (id, await fetch(id)) }
            }
            for await (id, outcome) in group {
                inFlight.remove(id)
                record(outcome, for: id)
            }
        }
    }
}

/// Whether background work that needs the network should run: online, and not in
/// Low Power Mode.
public final class NetworkConditions: Sendable {
    private let monitor = NWPathMonitor()
    private let online = Mutex(true)
    private let handler = Mutex<(@Sendable (Bool) -> Void)?>(nil)

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isOnline = path.status == .satisfied
            let changed = self.online.withLock { value -> Bool in
                defer { value = isOnline }
                return value != isOnline
            }
            if changed { self.handler.withLock { $0 }?(isOnline) }
        }
        monitor.start(queue: DispatchQueue(label: "ferry.network-conditions", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    public var isOnline: Bool { online.withLock { $0 } }

    /// Called (on a background queue) whenever connectivity changes.
    public func onChange(_ handler: @escaping @Sendable (Bool) -> Void) {
        self.handler.withLock { $0 = handler }
    }

    public var allowsBackgroundFetch: Bool {
        isOnline && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

extension Duration {
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

extension FetchOutcome {
    /// Classifies a fetch error for scheduling.
    public init(_ error: Error?) {
        guard let error else { self = .success; return }
        switch (error as? GitError)?.kind {
        case .network, .timedOut: self = .network
        case .authenticationRequired, .sshKeyRejected, .hostKeyVerificationFailed: self = .authentication
        default: self = .failed
        }
    }
}
