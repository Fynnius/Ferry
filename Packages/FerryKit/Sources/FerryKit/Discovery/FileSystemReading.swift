import Foundation
import Darwin

/// One item in a directory listing, described from metadata only.
public struct DirectoryEntry: Hashable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    /// A cloud placeholder whose contents aren't on this Mac. Opening it would download it.
    public var isPlaceholder: Bool

    public init(name: String, isDirectory: Bool, isSymbolicLink: Bool = false, isPlaceholder: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isPlaceholder = isPlaceholder
    }
}

/// Everything the scanner reads from disk goes through here, so tests can simulate
/// cloud placeholders (a real dataless iCloud file can't be fabricated in a unit test)
/// and check that the scanner never opens one.
public protocol FileSystemReading: Sendable {
    /// Lists a directory. Throws when it can't be read (missing, permission denied).
    func entries(of directory: URL) throws -> [DirectoryEntry]
    /// Whether a single item is a cloud placeholder. Metadata only — never downloads.
    func isPlaceholder(_ url: URL) -> Bool
    /// Reads a small file. The scanner only calls this after `isPlaceholder` said no.
    func contents(of file: URL) throws -> Data
}

/// The real disk. Placeholder state comes from `URLResourceValues` (iCloud) and the
/// APFS `SF_DATALESS` flag (iCloud and File Provider apps like Dropbox or OneDrive);
/// both are metadata reads that don't trigger a download.
public struct LocalFileSystem: FileSystemReading {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    /// `SF_DATALESS` from `<sys/stat.h>`: the file's data lives in the cloud.
    private static let datalessFlag: UInt32 = 0x4000_0000

    public init() {}

    public func entries(of directory: URL) throws -> [DirectoryEntry] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Self.keys, options: [])
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(Self.keys))
            let isDirectory = values?.isDirectory ?? false
            var placeholder = Self.isNotDownloaded(values)
            // Directories are about to be listed, so check the dataless flag too.
            if isDirectory, !placeholder { placeholder = Self.isDataless(url) }
            return DirectoryEntry(
                name: url.lastPathComponent,
                isDirectory: isDirectory,
                isSymbolicLink: values?.isSymbolicLink ?? false,
                isPlaceholder: placeholder
            )
        }
    }

    public func isPlaceholder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return Self.isNotDownloaded(values) || Self.isDataless(url)
    }

    public func contents(of file: URL) throws -> Data {
        try Data(contentsOf: file)
    }

    private static func isNotDownloaded(_ values: URLResourceValues?) -> Bool {
        values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    private static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & datalessFlag != 0
    }
}

/// The real path of an existing item (symlinks and `/var` → `/private/var` resolved), or
/// nil when nothing is there. Paths git writes into `.git` files are real paths, so
/// everything the scanner compares goes through this.
func canonicalURL(_ url: URL) -> URL? {
    guard let resolved = realpath(url.path, nil) else { return nil }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

/// A directory URL built from a path string, so equal paths always give equal URLs
/// (`URL(fileURLWithPath:)` alone adds a trailing slash only if the folder exists).
func directoryURL(_ path: String) -> URL {
    URL(fileURLWithPath: normalizedPath(path), isDirectory: true)
}

/// Removes `.`, `..` and repeated slashes without touching the disk. Not
/// `standardizedFileURL`: that also strips a leading `/private`, which breaks comparisons
/// with the real paths git writes (`/private/var/…`).
func normalizedPath(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/") {
        if part == "." { continue }
        if part == ".." {
            if !parts.isEmpty { parts.removeLast() }
            continue
        }
        parts.append(part)
    }
    return "/" + parts.joined(separator: "/")
}
