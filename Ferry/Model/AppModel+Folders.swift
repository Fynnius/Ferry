import Foundation
import FerryKit

/// A folder handed to Ferry from outside the Add Folder… panel.
enum DroppedFolder: Equatable {
    /// The folder is a repo itself (has `.git`, a directory or a worktree's file): it is
    /// added on its own, like Add Repository…
    case repository(URL)
    /// Any other folder is scanned for repos, like Add Folder…
    case root(URL)

    var url: URL {
        switch self {
        case .repository(let url), .root(let url): url
        }
    }

    /// Nil for files, packages and paths that don't exist.
    static func classify(_ url: URL, fileManager: FileManager = .default) -> DroppedFolder? {
        guard url.isFileURL else { return nil }
        let url = url.standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values?.isDirectory == true, values?.isPackage != true else { return nil }
        let hasGit = fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
        return hasGit ? .repository(url) : .root(url)
    }
}

/// Folders dropped on the window or the Dock icon, or sent by Finder's Open in Ferry
/// service, all go through `openFolders(_:)`. A repo folder becomes a manual repo, any
/// other folder a scan root; then Ferry shows what it found there.
extension AppModel {
    /// Returns false when none of the URLs is a folder (so a drop can be refused).
    @discardableResult
    func openFolders(_ urls: [URL]) -> Bool {
        let folders = urls.compactMap { DroppedFolder.classify($0) }
        guard !folders.isEmpty else { return false }
        droppedFolders.append(contentsOf: folders.map(\.url))
        addDroppedFoldersIfReady()
        return true
    }

    /// Runs once the fleet is ready. Until then the folders wait in `droppedFolders`:
    /// while starting up, or during onboarding, which takes them into its own folder list.
    func addDroppedFoldersIfReady() {
        guard phase == .ready, !droppedFolders.isEmpty else { return }
        let folders = droppedFolders.compactMap { DroppedFolder.classify($0) }
        droppedFolders = []
        Task { await add(folders) }
    }

    private func add(_ folders: [DroppedFolder]) async {
        var changed = false
        for folder in folders {
            switch folder {
            case .repository(let url):
                if repoItem(at: url) != nil { continue }
                if let hidden = grouping.hidden.first(where: { Self.samePath($0.primary.url, url) }) {
                    discovery.overrides.setHidden(hidden.id, false)
                } else {
                    discovery.overrides.addManualRepo(url)
                }
                changed = true
            case .root(let url):
                if isScanned(url) { continue }
                discovery.roots.append(ScanRoot(url: url))
                changed = true
            }
        }
        if changed {
            saveDiscovery()
            // A scan already running wouldn't include the new folders; wait it out.
            while isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            await rescan()
        }
        reveal(folders)
    }

    /// Selects what the folders brought in: their project when they share one, else All
    /// Repositories, scrolled to the first repo.
    private func reveal(_ folders: [DroppedFolder]) {
        let found = allRepos.filter { repo in
            folders.contains { folder in
                switch folder {
                case .repository(let url): Self.samePath(repo.path, url)
                case .root(let url): Self.isInside(repo.path, url)
                }
            }
        }
        guard let first = found.first else {
            let names = folders.map { "“\($0.url.lastPathComponent)”" }.joined(separator: ", ")
            fleetNotice = "No git repositories found in \(names)."
            return
        }
        let projectIDs = Set(found.compactMap { repo in projects.first { $0.repos.contains { $0 === repo } }?.id })
        selection = projectIDs.count == 1 ? projectIDs.first.map(SidebarItem.project) : .all
        currentRepoID = first.id
        scrollTarget = first.id
    }

    private func repoItem(at url: URL) -> RepoItem? {
        allRepos.first { Self.samePath($0.path, url) }
    }

    /// Already a root, or inside one whose scan reached it — adding it again would only
    /// clutter Settings → Folders.
    private func isScanned(_ url: URL) -> Bool {
        discovery.roots.contains { root in
            Self.samePath(root.url, url)
                || (Self.isInside(url, root.url) && allRepos.contains { Self.isInside($0.path, url) })
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        canonicalPath(a) == canonicalPath(b)
    }

    /// `url` is `folder` or somewhere below it.
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = canonicalPath(url), base = canonicalPath(folder)
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}
