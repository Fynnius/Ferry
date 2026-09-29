import Foundation

/// A remote URL reduced to host/owner/name, so `git@github.com:Acme/App.git`,
/// `https://github.com/acme/app` and `ssh://git@github.com/acme/app.git` all compare
/// equal. This is what detects duplicate clones and same-org repos.
public struct RemoteIdentity: Hashable, Sendable, Codable {
    /// Lowercased host, e.g. `github.com`. Empty for local paths and `file://` remotes.
    public var host: String
    /// Everything between host and name, original case: `Acme`, or `group/subgroup` on GitLab.
    /// For local remotes, the containing folder's path.
    public var owner: String
    /// Repository name without `.git`, original case.
    public var name: String

    public init(host: String, owner: String, name: String) {
        self.host = host.lowercased()
        self.owner = owner
        self.name = name
    }

    /// Parses the URL forms git accepts: `scheme://[user@]host[:port]/path`, scp-like
    /// `[user@]host:path`, `file://` and plain paths. Nil when nothing usable is left.
    public init?(remoteURL raw: String) {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }

        var host = ""
        var path: String
        if let schemeEnd = url.range(of: "://") {
            let scheme = url[..<schemeEnd.lowerBound].lowercased()
            let rest = url[schemeEnd.upperBound...]
            if scheme == "file" {
                path = String(rest)
            } else {
                let slash = rest.firstIndex(of: "/") ?? rest.endIndex
                var authority = rest[..<slash]
                if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
                // A port, or the scp-style colon some people write inside ssh:// URLs.
                if let colon = authority.firstIndex(of: ":") { authority = authority[..<colon] }
                host = String(authority)
                path = String(rest[slash...])
            }
        } else if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
            // git's rule: a colon before any slash means scp-like syntax.
            var authority = url[..<colon]
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            host = String(authority)
            path = String(url[url.index(after: colon)...])
        } else {
            path = url
        }

        var components = path.split(separator: "/").map(String.init)
        guard var name = components.popLast() else { return nil }
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        guard !name.isEmpty else { return nil }
        if host.isEmpty {
            // Local remote: keep the absolute folder so two different local remotes stay distinct.
            let folder = components.joined(separator: "/")
            self.init(host: "", owner: path.hasPrefix("/") ? "/" + folder : folder, name: name)
        } else {
            self.init(host: host, owner: components.joined(separator: "/"), name: name)
        }
    }

    public var isLocal: Bool { host.isEmpty }

    /// Case-insensitive key: GitHub, GitLab and Bitbucket treat owner and name that way,
    /// and two clones differing only in URL case are the same repo.
    public var key: String {
        isLocal ? "local:\(owner)/\(name)" : "\(host)/\(owner)/\(name)".lowercased()
    }

    /// Key of the owner, for "same org" grouping. Nil for local remotes: a folder of
    /// bare repos on disk says nothing about which projects belong together.
    public var ownerKey: String? {
        guard !isLocal, !owner.isEmpty else { return nil }
        return "\(host)/\(owner)".lowercased()
    }

    /// "GitHub" rather than "github.com" in user-facing text.
    public var hostDisplayName: String {
        switch host {
        case "github.com": "GitHub"
        case "gitlab.com": "GitLab"
        case "bitbucket.org": "Bitbucket"
        case "codeberg.org": "Codeberg"
        default: host
        }
    }
}
