import Foundation

/// What discovery remembers between launches: where to scan and the user's corrections.
public struct DiscoverySettings: Hashable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var roots: [ScanRoot]
    public var overrides: DiscoveryOverrides

    public init(roots: [ScanRoot] = [], overrides: DiscoveryOverrides = DiscoveryOverrides()) {
        self.version = Self.currentVersion
        self.roots = roots
        self.overrides = overrides
    }

    /// The roots plus manually added repos, each checked as a root of depth 0.
    public var scanRoots: [ScanRoot] {
        roots + overrides.manualRepos
            .filter { repo in !roots.contains { $0.url == repo } }
            .map { ScanRoot(url: $0, maxDepth: 0) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        roots = try c.decodeIfPresent([ScanRoot].self, forKey: .roots) ?? []
        overrides = try c.decodeIfPresent(DiscoveryOverrides.self, forKey: .overrides) ?? DiscoveryOverrides()
    }
}

/// JSON files in a folder the app chooses (Application Support): `discovery.json` for
/// settings, `last-scan.json` for the previous scan that the next rescan is diffed against.
/// Writes are atomic, so a crash mid-save leaves the old file intact.
public struct DiscoveryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var settingsURL: URL { directory.appendingPathComponent("discovery.json") }
    public var lastScanURL: URL { directory.appendingPathComponent("last-scan.json") }

    /// Defaults when there's no file yet. A file that can't be decoded is moved aside to
    /// `discovery.json.unreadable` (never overwritten, so nothing is silently lost) and
    /// defaults are returned: onboarding again beats an app that won't start.
    public func loadSettings() -> DiscoverySettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return DiscoverySettings() }
        do {
            return try JSONDecoder().decode(DiscoverySettings.self, from: data)
        } catch {
            let aside = directory.appendingPathComponent("discovery.json.unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: settingsURL, to: aside)
            return DiscoverySettings()
        }
    }

    public func save(_ settings: DiscoverySettings) throws {
        try write(settings, to: settingsURL)
    }

    /// Nil when there's no previous scan or it can't be read; the next scan is then
    /// treated as the first (nothing is announced as new).
    public func loadLastScan() -> ScanResult? {
        guard let data = try? Data(contentsOf: lastScanURL) else { return nil }
        return try? JSONDecoder().decode(ScanResult.self, from: data)
    }

    public func saveLastScan(_ scan: ScanResult) throws {
        try write(scan, to: lastScanURL)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
