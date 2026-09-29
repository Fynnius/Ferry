/// Caps how many git processes run at once across all repos (6–8 is plenty),
/// so a refresh of 60 repos doesn't fork 60 processes simultaneously.
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(permits: Int) {
        available = permits
    }

    public func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await wait()
        defer { signal() }
        try Task.checkCancellation()
        return try await operation()
    }
}

/// Runs operations one at a time, in submission order — one per repo for writes, so
/// two commits or a commit and a pull never race for `index.lock`.
public actor SerialExecutor {
    private var tail: Task<Void, Never>?

    public init() {}

    @discardableResult
    public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
