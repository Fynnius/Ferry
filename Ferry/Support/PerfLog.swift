import Foundation

/// Timing lines for performance measurements, printed only when FERRY_PERF_LOG is set.
enum PerfLog {
    static let enabled = ProcessInfo.processInfo.environment["FERRY_PERF_LOG"] != nil

    static func mark(_ event: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("PERF \(event) \(Date().timeIntervalSince1970)\n".utf8))
    }
}
