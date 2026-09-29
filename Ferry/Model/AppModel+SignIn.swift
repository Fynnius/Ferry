import Foundation
import FerryKit

/// Signing in to HTTPS remotes. Background fetches never prompt (`backgroundFetch`);
/// repos they couldn't fetch carry `signInHost`, and the stack sums them up in one
/// notice per host. From there the user connects the GitHub CLI, or signs in once for
/// another host, and the waiting repos are fetched again.
extension AppModel {
    struct SignInGroup: Identifiable {
        var host: String
        var repos: [RepoItem]
        var id: String { host }
        var isGitHub: Bool { host == GitHubCLI.host }
    }

    /// Repos waiting for a sign-in, by host, most repos first. Dismissed hosts are left out.
    var signInGroups: [SignInGroup] {
        Dictionary(grouping: allRepos.filter { $0.signInHost != nil }) { $0.signInHost ?? "" }
            .filter { !dismissedSignInHosts.contains($0.key) }
            .map { SignInGroup(host: $0.key, repos: $0.value) }
            .sorted { ($0.repos.count, $1.host) > ($1.repos.count, $0.host) }
    }

    /// How git signs in to GitHub on this Mac. Reads only; nil before git is set up.
    func gitHubSignInStatus() async -> GitHubSignInStatus? {
        guard let runner else { return nil }
        return await GitHubSignInStatus.read(runner: runner, in: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Connect GitHub CLI: `gh auth setup-git` (the user's global git config gains gh as
    /// the helper for github.com), then fetch the repos that were waiting for it.
    func connectGitHubCLI() async throws {
        guard let runner, let cli = GitHubCLI(environment: runner.baseEnvironment) else {
            throw GitHubCLIError(message: "The GitHub CLI (gh) isn't installed.")
        }
        try await cli.setUpGit()
        Log.git.info("connected the GitHub CLI as git's credential helper for github.com")
        dismissedSignInHosts.remove(GitHubCLI.host)
        await retryAfterSignIn(host: GitHubCLI.host)
    }

    /// Fetches the repos waiting on `host` again, without prompts; those that work stop waiting.
    func retryAfterSignIn(host: String) async {
        let waiting = allRepos.filter { $0.signInHost == host }
        await withTaskGroup(of: Void.self) { group in
            for repo in waiting {
                group.addTask {
                    if await self.backgroundFetch(repo.id) == .success {
                        await self.fetchedManually(repo)
                    }
                }
            }
        }
    }

    /// Any other host: fetch one waiting repo in the foreground, where git asks for the
    /// sign-in and the user's credential helper keeps it; then the rest, quietly.
    func signIn(host: String) async {
        guard let first = allRepos.first(where: { $0.signInHost == host }) else { return }
        await first.fetch()
        if first.signInHost == nil {
            await retryAfterSignIn(host: host)
        }
    }

    func dismissSignInNotice(host: String) {
        dismissedSignInHosts.insert(host)
    }
}
