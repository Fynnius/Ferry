import Foundation
import Observation
import FerryKit

/// User preferences, persisted in UserDefaults. Secrets never live here (the API key
/// is in the Keychain).
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var autoFetch: Bool { didSet { defaults.set(autoFetch, forKey: Keys.autoFetch) } }
    var fetchIntervalMinutes: Int { didSet { defaults.set(fetchIntervalMinutes, forKey: Keys.fetchInterval) } }
    var pullStrategy: GitRepository.PullStrategy { didSet { defaults.set(pullStrategy.rawValue, forKey: Keys.pullStrategy) } }
    var gitPath: String { didSet { defaults.set(gitPath, forKey: Keys.gitPath) } }
    var protectedBranches: [String] { didSet { defaults.set(protectedBranches, forKey: Keys.protectedBranches) } }
    /// Repos (by id) whose protected-branch confirmation the user turned off.
    var protectedBranchConfirmationSkipped: Set<String> { didSet { defaults.set(Array(protectedBranchConfirmationSkipped), forKey: Keys.protectedSkipped) } }
    var editorBundleID: String { didSet { defaults.set(editorBundleID, forKey: Keys.editor) } }
    var terminalBundleID: String { didSet { defaults.set(terminalBundleID, forKey: Keys.terminal) } }
    var aiModel: String { didSet { defaults.set(aiModel, forKey: Keys.aiModel) } }
    var showMenuBarExtra: Bool { didSet { defaults.set(showMenuBarExtra, forKey: Keys.menuBar) } }
    /// The Dock icon's badge counts repos that need attention. On by default, like Mail's
    /// unread count: it is the one number Ferry exists to show, and it never pops up.
    var showDockBadge: Bool { didSet { defaults.set(showDockBadge, forKey: Keys.dockBadge) } }
    var globalHotKeyEnabled: Bool { didSet { defaults.set(globalHotKeyEnabled, forKey: Keys.hotKey) } }
    var privacyMode: Bool { didSet { defaults.set(privacyMode, forKey: Keys.privacy) } }
    /// The user has seen, once, what ✨ sends to OpenAI and what OpenAI keeps.
    var aiNoticeAcknowledged: Bool { didSet { defaults.set(aiNoticeAcknowledged, forKey: Keys.aiNotice) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoFetch = defaults.object(forKey: Keys.autoFetch) == nil ? true : defaults.bool(forKey: Keys.autoFetch)
        fetchIntervalMinutes = defaults.object(forKey: Keys.fetchInterval) == nil ? 3 : defaults.integer(forKey: Keys.fetchInterval)
        pullStrategy = defaults.string(forKey: Keys.pullStrategy).flatMap(GitRepository.PullStrategy.init(rawValue:)) ?? .merge
        gitPath = defaults.string(forKey: Keys.gitPath) ?? ""
        protectedBranches = defaults.stringArray(forKey: Keys.protectedBranches) ?? ["main", "master"]
        protectedBranchConfirmationSkipped = Set(defaults.stringArray(forKey: Keys.protectedSkipped) ?? [])
        editorBundleID = defaults.string(forKey: Keys.editor) ?? ""
        terminalBundleID = defaults.string(forKey: Keys.terminal) ?? "com.apple.Terminal"
        aiModel = defaults.string(forKey: Keys.aiModel) ?? "gpt-6-luna"
        showMenuBarExtra = defaults.object(forKey: Keys.menuBar) == nil ? false : defaults.bool(forKey: Keys.menuBar)
        showDockBadge = defaults.object(forKey: Keys.dockBadge) == nil ? true : defaults.bool(forKey: Keys.dockBadge)
        globalHotKeyEnabled = defaults.object(forKey: Keys.hotKey) == nil ? false : defaults.bool(forKey: Keys.hotKey)
        privacyMode = defaults.object(forKey: Keys.privacy) == nil ? false : defaults.bool(forKey: Keys.privacy)
        aiNoticeAcknowledged = defaults.bool(forKey: Keys.aiNotice)
    }

    func isProtected(branch: String?) -> Bool {
        guard let branch else { return false }
        return protectedBranches.contains(branch)
    }

    var fetchPolicy: FetchPolicy {
        FetchPolicy(interval: .seconds(max(1, fetchIntervalMinutes) * 60))
    }

    private enum Keys {
        static let autoFetch = "autoFetch"
        static let fetchInterval = "fetchIntervalMinutes"
        static let pullStrategy = "pullStrategy"
        static let gitPath = "gitPath"
        static let protectedBranches = "protectedBranches"
        static let protectedSkipped = "protectedBranchConfirmationSkipped"
        static let editor = "editorBundleID"
        static let terminal = "terminalBundleID"
        static let aiModel = "aiModel"
        static let menuBar = "showMenuBarExtra"
        static let dockBadge = "showDockBadge"
        static let hotKey = "globalHotKeyEnabled"
        static let privacy = "privacyMode"
        static let aiNotice = "aiNoticeAcknowledged"
    }
}
