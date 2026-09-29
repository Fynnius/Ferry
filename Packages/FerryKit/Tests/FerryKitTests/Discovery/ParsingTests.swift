import Foundation
import Testing
@testable import FerryKit

@Suite("Remote identity")
struct RemoteIdentityTests {
    @Test(arguments: [
        "git@github.com:Acme/Harbor.git",
        "https://github.com/acme/harbor",
        "https://github.com/acme/harbor.git/",
        "ssh://git@github.com/acme/harbor.git",
        "ssh://git@github.com:22/acme/harbor.git",
        "https://user:token@github.com/Acme/harbor.git",
        "git://github.com/acme/harbor",
    ])
    func githubFormsNormaliseToOneKey(url: String) throws {
        let identity = try #require(RemoteIdentity(remoteURL: url))
        #expect(identity.key == "github.com/acme/harbor")
        #expect(identity.ownerKey == "github.com/acme")
        #expect(identity.hostDisplayName == "GitHub")
    }

    @Test func keepsOriginalCaseForDisplay() throws {
        let identity = try #require(RemoteIdentity(remoteURL: "git@github.com:Acme-xyz/HarborApp.git"))
        #expect(identity.owner == "Acme-xyz")
        #expect(identity.name == "HarborApp")
    }

    @Test func nestedGroupsBecomeTheOwner() throws {
        let identity = try #require(RemoteIdentity(remoteURL: "https://gitlab.com/acme/platform/harbor.git"))
        #expect(identity.owner == "acme/platform")
        #expect(identity.name == "harbor")
        #expect(identity.hostDisplayName == "GitLab")
    }

    @Test func localRemotesAreDistinctAndHaveNoOwner() throws {
        let a = try #require(RemoteIdentity(remoteURL: "/srv/git/harbor.git"))
        let b = try #require(RemoteIdentity(remoteURL: "file:///srv/other/harbor.git"))
        #expect(a.isLocal && b.isLocal)
        #expect(a.key != b.key)
        #expect(a.ownerKey == nil)
    }

    @Test func differentHostsDiffer() {
        #expect(RemoteIdentity(remoteURL: "git@github.com:acme/harbor.git")?.key != RemoteIdentity(remoteURL: "git@gitlab.com:acme/harbor.git")?.key)
    }

    @Test(arguments: ["", "   ", "https://github.com/", ".git"])
    func garbageIsNil(url: String) {
        #expect(RemoteIdentity(remoteURL: url) == nil)
    }
}

@Suite("Manifest parsing")
struct ManifestParsingTests {
    @Test func workspaceFileWithCommentsAndTrailingCommas() throws {
        let json = """
        {
          // Saved by VS Code
          "folders": [
            { "path": "harbor-app" }, /* main app */
            { "path": "../Shared/brand" },
            { "name": "abs", "path": "/opt/code/tools" },
            { "uri": "file:///opt/code/docs" },
            { "uri": "vscode-remote://ssh-remote+box/home/x" },
          ],
          "settings": { "url": "http://example.com//not-a-comment" },
        }
        """
        let base = URL(fileURLWithPath: "/work/Harbor", isDirectory: true)
        let folders = try #require(ManifestParsing.workspaceFolders(Data(json.utf8), relativeTo: base))
        #expect(folders.map(\.path) == ["/work/Harbor/harbor-app", "/work/Shared/brand", "/opt/code/tools", "/opt/code/docs"])
    }

    @Test func nonWorkspaceJSONIsNil() {
        #expect(ManifestParsing.workspaceFolders(Data("{\"a\": 1}".utf8), relativeTo: URL(fileURLWithPath: "/")) == nil)
        #expect(ManifestParsing.workspaceFolders(Data("not json".utf8), relativeTo: URL(fileURLWithPath: "/")) == nil)
    }

    @Test func pnpmPackagesBlockAndFlowStyles() {
        #expect(ManifestParsing.pnpmPackageGlobs("packages:\n  - 'apps/*'\n  - \"libs/*\" # shared\n  - '!**/test/**'\ncatalog:\n  react: 19\n") == ["apps/*", "libs/*", "!**/test/**"])
        #expect(ManifestParsing.pnpmPackageGlobs("packages:\n- apps/*\n") == ["apps/*"])
        #expect(ManifestParsing.pnpmPackageGlobs("packages: ['apps/*', \"tools/cli\"]\n") == ["apps/*", "tools/cli"])
    }

    @Test func pnpmBuildSettingsOnlyIsNotAMonorepo() {
        // pnpm 10+ keeps build approvals here in ordinary repos.
        #expect(ManifestParsing.pnpmPackageGlobs("overrides:\n  semver: ^7\nonlyBuiltDependencies:\n  - esbuild\n").isEmpty)
    }

    @Test func packageJSONWorkspacesBothShapes() {
        #expect(ManifestParsing.packageJSONWorkspaceGlobs(Data("{\"workspaces\": [\"packages/*\"]}".utf8)) == ["packages/*"])
        #expect(ManifestParsing.packageJSONWorkspaceGlobs(Data("{\"workspaces\": {\"packages\": [\"apps/*\"]}}".utf8)) == ["apps/*"])
        #expect(ManifestParsing.packageJSONWorkspaceGlobs(Data("{\"name\": \"x\"}".utf8)).isEmpty)
    }

    @Test func globsMustMatchRealFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-globs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("apps/web"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tools/cli"), withIntermediateDirectories: true)
        let fs = LocalFileSystem()
        #expect(ManifestParsing.anyGlobResolves(["apps/*"], in: root, fileSystem: fs))
        #expect(ManifestParsing.anyGlobResolves(["./tools/cli"], in: root, fileSystem: fs))
        #expect(ManifestParsing.anyGlobResolves(["app*/**"], in: root, fileSystem: fs))
        #expect(!ManifestParsing.anyGlobResolves(["packages/*"], in: root, fileSystem: fs))
        #expect(!ManifestParsing.anyGlobResolves(["!apps/*", "../outside/*"], in: root, fileSystem: fs))
    }

    @Test func submodulePathsFromGitmodules() {
        let text = "[submodule \"shared\"]\n\tpath = libs/shared\n\turl = ../shared.git\n[submodule \"evil\"]\n\tpath = ../escape\n"
        #expect(ManifestParsing.submodulePaths(text) == ["libs/shared"])
    }

    @Test(arguments: [
        ("harbor-app", "harbor"), ("TideAdmin", "Tide"), ("HarborApp", "Harbor"),
        ("api", "api"), ("go", nil), ("_tools", "tools"), ("tide_web", "tide"),
    ] as [(String, String?)])
    func stems(name: String, expected: String?) {
        #expect(ProjectGrouper.stem(of: name)?.display == expected)
    }
}
