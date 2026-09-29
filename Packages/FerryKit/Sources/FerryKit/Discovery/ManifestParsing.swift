import Foundation
import Darwin

/// Readers for the few manifest files discovery cares about. Each is deliberately
/// minimal: it extracts one list and treats anything it doesn't understand as absent.
enum ManifestParsing {
    // MARK: - .code-workspace

    /// Folder entries of a `.code-workspace` file, resolved against the file's folder.
    /// VS Code writes these as JSON with comments and trailing commas, so both are allowed.
    /// Nil when the file isn't a workspace at all.
    static func workspaceFolders(_ data: Data, relativeTo base: URL) -> [URL]? {
        let text = strippingTrailingCommas(strippingComments(String(decoding: data, as: UTF8.self)))
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let folders = object["folders"] as? [[String: Any]] else { return nil }
        return folders.compactMap { folder in
            if let path = folder["path"] as? String, !path.isEmpty {
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
                return directoryURL(url.path)
            }
            // `uri` entries can point at remote machines; only local folders count.
            if let uri = folder["uri"] as? String, let url = URL(string: uri), url.isFileURL {
                return directoryURL(url.path)
            }
            return nil
        }
    }

    static func strippingComments(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var chars = Array(text.unicodeScalars)[...]
        var inString = false
        while let c = chars.popFirst() {
            if inString {
                result.unicodeScalars.append(c)
                if c == "\\", let next = chars.popFirst() { result.unicodeScalars.append(next) }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
                result.unicodeScalars.append(c)
            } else if c == "/", chars.first == "/" {
                while let n = chars.first, n != "\n" { chars.removeFirst() }
            } else if c == "/", chars.first == "*" {
                chars.removeFirst()
                while let n = chars.popFirst() {
                    if n == "*", chars.first == "/" { chars.removeFirst(); break }
                }
            } else {
                result.unicodeScalars.append(c)
            }
        }
        return result
    }

    static func strippingTrailingCommas(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var inString = false
        var index = 0
        while index < scalars.count {
            let c = scalars[index]
            if inString {
                result.append(c)
                if c == "\\", index + 1 < scalars.count { index += 1; result.append(scalars[index]) }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
                result.append(c)
            } else if c == "," {
                var next = index + 1
                while next < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[next]) { next += 1 }
                if next < scalars.count, scalars[next] == "]" || scalars[next] == "}" {
                    // Drop it: a trailing comma.
                } else {
                    result.append(c)
                }
            } else {
                result.append(c)
            }
            index += 1
        }
        return String(result)
    }

    // MARK: - .gitmodules

    /// Checkout paths from `.gitmodules`; paths escaping the repo are ignored.
    static func submodulePaths(_ gitmodules: String) -> [String] {
        gitmodules.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "path", !parts[1].isEmpty, !parts[1].contains("..") else { return nil }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    // MARK: - Monorepo manifests

    /// The `packages:` globs of a `pnpm-workspace.yaml`. pnpm 10+ also uses this file for
    /// build settings (`overrides`, `onlyBuiltDependencies`…) in ordinary repos, so an
    /// empty result means "not a monorepo" (a common false positive).
    static func pnpmPackageGlobs(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("packages:") }) else { return [] }
        let inline = lines[start].dropFirst("packages:".count).trimmingCharacters(in: .whitespaces)
        if inline.hasPrefix("[") {
            return inline.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",").map { unquoted(String($0)) }.filter { !$0.isEmpty }
        }
        var globs: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("-") {
                var item = String(trimmed.dropFirst())
                if let comment = item.range(of: " #") { item = String(item[..<comment.lowerBound]) }
                let glob = unquoted(item)
                if !glob.isEmpty { globs.append(glob) }
            } else if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                break // Next top-level key.
            }
        }
        return globs
    }

    /// `workspaces` globs from a `package.json` (array form, or Yarn's `{ packages: [...] }`).
    static func packageJSONWorkspaceGlobs(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let list = object["workspaces"] as? [String] { return list }
        if let nested = object["workspaces"] as? [String: Any], let list = nested["packages"] as? [String] { return list }
        return []
    }

    /// Whether any positive glob matches at least one real folder under `root`. Only
    /// directory names are listed — nothing is opened — and placeholders don't count.
    static func anyGlobResolves(_ globs: [String], in root: URL, fileSystem: any FileSystemReading) -> Bool {
        globs.contains { glob in
            guard !glob.hasPrefix("!") else { return false }
            var pattern = glob
            while pattern.hasPrefix("./") { pattern.removeFirst(2) }
            let parts = pattern.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
            guard !parts.isEmpty, !parts.contains("..") else { return false }
            var current = [root]
            for part in parts {
                current = current.flatMap { dir -> [URL] in
                    guard let entries = try? fileSystem.entries(of: dir) else { return [] }
                    return entries
                        .filter { $0.isDirectory && !$0.isSymbolicLink && !$0.isPlaceholder && matches($0.name, part) }
                        .map { dir.appendingPathComponent($0.name, isDirectory: true) }
                }
                if current.isEmpty { return false }
            }
            return true
        }
    }

    private static func matches(_ name: String, _ pattern: String) -> Bool {
        if pattern == "**" { return !name.hasPrefix(".") }
        return fnmatch(pattern, name, 0) == 0
    }

    private static func unquoted(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }
}
