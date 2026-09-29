import SwiftUI
import AppKit
import FerryKit

/// First run: welcome → choose folders → live scan → choose repos → connect GitHub (only
/// when needed) → extras. Every macOS permission prompt is explained before the choice
/// that causes it.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, folders, scanning, review, github, extras
    }

    @Environment(AppModel.self) private var app
    @State private var step: Step = .welcome
    @State private var choices: [FolderChoice] = FolderChoice.suggestions()
    @State private var scanTask: Task<Void, Never>?
    /// Stop and Continue: the scan returns what it found so far, then the review shows.
    @State private var stopRequested = false
    /// Repos the user unchecked in the review; hidden when onboarding finishes.
    @State private var unchecked: Set<RepoID> = []
    @State private var github = GitHubConnection()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .folders: folders
                case .scanning: scanning
                case .review: review
                case .github: githubStep
                case .extras: OnboardingExtras { app.finishOnboarding(hiding: unchecked) }
                }
            }
            .frame(maxWidth: 560)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .animation(Motion.snappy, value: step)
        .folderDropTarget(cornerRadius: 16, inset: 12)
        .onChange(of: app.droppedFolders, initial: true) { takeDroppedFolders() }
        .task(id: step) {
            // Read while the user reviews, so Continue knows at once whether GitHub needs a step.
            if step == .review, !app.httpsGitHubRepos(excluding: []).isEmpty {
                await github.load(app)
            }
        }
    }

    /// Folders dropped on the window or the Dock icon, or sent from Finder. On the folder
    /// step they join the list (the user is choosing); anywhere else they're scanned right
    /// away — on the welcome step just them, since nothing else has been shown yet.
    private func takeDroppedFolders() {
        let urls = app.droppedFolders
        guard !urls.isEmpty else { return }
        app.droppedFolders = []
        if step == .welcome {
            for index in choices.indices { choices[index].isOn = false }
        }
        for url in urls {
            if let index = choices.firstIndex(where: { AppModel.samePath($0.url, url) }) {
                choices[index].isOn = true
            } else {
                choices.append(FolderChoice(url: url, isOn: true, note: nil))
            }
        }
        guard step != .folders else { return }
        scanTask?.cancel()
        startScan()
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Welcome to Ferry")
                .font(.largeTitle.weight(.semibold))
            Text("See every repository that needs you in one calm list. Write a message, commit and push — without opening an editor.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose Folders") { step = .folders }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
    }

    // MARK: Folders

    private var folders: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where do you keep your projects?")
                .font(.title2.weight(.semibold))
            Text("Ferry looks for git repositories inside these folders and groups related ones into projects. It only reads — nothing changes until you commit.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach($choices) { $choice in
                    Toggle(isOn: $choice.isOn) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.displayPath)
                            if let note = choice.note {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    if choice.id != choices.last?.id { Divider() }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("Add Another Folder…", action: addFolder)
                Spacer()
                Button("Back") { step = .welcome }
                Button("Scan") { startScan() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!choices.contains(where: \.isOn))
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !choices.contains(where: { $0.url == url }) {
            choices.append(FolderChoice(url: url, isOn: true, note: nil))
        }
    }

    private func startScan() {
        step = .scanning
        stopRequested = false
        let roots = choices.filter(\.isOn).map(\.url)
        scanTask = Task {
            await app.startOnboardingScan(roots: roots)
            // Cancelled for a new scan (folders dropped): that one shows the review.
            guard !Task.isCancelled || stopRequested else { return }
            showReview()
        }
    }

    private func showReview() {
        // Long-untouched repos start unchecked; everything else is shown.
        unchecked = Set(app.grouping.visibleRepos.filter { AppModel.isDormant($0) }.map(\.id))
        step = .review
    }

    /// Only when chosen repos use GitHub over HTTPS and git can't sign in there yet.
    private func continueFromReview() {
        guard !app.httpsGitHubRepos(excluding: unchecked).isEmpty else {
            step = .extras
            return
        }
        Task {
            let status = await github.load(app)
            step = status?.isReady == false ? .github : .extras
        }
    }

    // MARK: Scanning

    private var scanning: some View {
        VStack(spacing: 16) {
            Text(app.scanFound.count == 1 ? "1 repository found" : "\(app.scanFound.count) repositories found")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(app.scanFound.count)))
                .animation(Motion.smooth, value: app.scanFound.count)
            if let folder = app.scanProgress?.currentFolder {
                Text("Looking in \((folder.path as NSString).abbreviatingWithTildeInPath)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(app.scanFound, id: \.url) { repo in
                            HStack {
                                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                                Text(repo.name)
                                Text((repo.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .id(repo.url)
                            .transition(.opacity)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: app.scanFound.count) {
                    if let last = app.scanFound.last { proxy.scrollTo(last.url, anchor: .bottom) }
                }
            }
            .frame(height: 260)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                ProgressView().controlSize(.small)
                Spacer()
                Button("Stop and Continue") {
                    stopRequested = true
                    scanTask?.cancel()
                }
                .help("Use what's been found so far. You can rescan later in Settings → Folders.")
            }
        }
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            if app.grouping.visibleRepos.isEmpty {
                Text("No repositories found")
                    .font(.title2.weight(.semibold))
                Text("None of the chosen folders contain git repositories. Try a different folder — for example the one you clone into.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Choose Other Folders") { step = .folders }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                RepoChecklist(unchecked: $unchecked, onBack: { step = .folders }, onContinue: continueFromReview)
            }
        }
    }

    // MARK: GitHub

    private var githubStep: some View {
        let count = app.httpsGitHubRepos(excluding: unchecked).count
        return VStack(alignment: .leading, spacing: 16) {
            Text("Connect GitHub")
                .font(.title2.weight(.semibold))
            Text("\(count == 1 ? "One of your repositories uses" : "\(count) of your repositories use") GitHub over HTTPS. GitHub doesn't accept passwords for git, so git needs a sign-in helper to fetch and push them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GitHubSignInDetail(connection: github)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Back") { step = .review }
                Spacer()
                if github.status?.isReady == true {
                    Button("Continue") { step = .extras }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip — I use SSH or another way") { step = .extras }
                        .help("Ferry works without this. Git asks for a sign-in when you push or pull, and background fetches of these repos wait until it can sign in.")
                }
            }
        }
    }
}

/// The review as a checklist: every repo found, grouped by project, checked unless it's
/// been untouched for months. Unchecked repos are hidden when onboarding finishes.
/// Space toggles the highlighted rows.
private struct RepoChecklist: View {
    @Binding var unchecked: Set<RepoID>
    var onBack: () -> Void
    var onContinue: () -> Void
    @Environment(AppModel.self) private var app
    @State private var filter = ""
    @State private var highlighted: Set<RepoID> = []

    private struct Section: Identifiable {
        var id: String
        var name: String
        var why: String
        var repos: [RepoEntry]
    }

    /// Past this many repos, a filter field helps find one.
    private static let filterThreshold = 12

    private var sections: [Section] {
        var all = app.grouping.projects.map { Section(id: $0.id.rawValue, name: $0.name, why: $0.why, repos: $0.repos) }
        if !app.grouping.other.isEmpty {
            all.append(Section(id: ProjectID.other.rawValue, name: Grouping.otherTitle, why: Grouping.otherWhy, repos: app.grouping.other))
        }
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.compactMap { section in
            if section.name.localizedCaseInsensitiveContains(query) { return section }
            var section = section
            section.repos = section.repos.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return section.repos.isEmpty ? nil : section
        }
    }

    private var total: Int { app.grouping.visibleRepos.count }
    private var selectedCount: Int { app.grouping.visibleRepos.filter { !unchecked.contains($0.id) }.count }
    private var dormantCount: Int { app.grouping.visibleRepos.filter { AppModel.isDormant($0) }.count }

    var body: some View {
        let sections = sections
        let shown = sections.flatMap(\.repos).map(\.id)
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose what Ferry shows")
                .font(.title2.weight(.semibold))
            Text("Ferry grouped your repositories into projects. Uncheck the ones you don't need — they're hidden, not changed, and Settings → Folders brings them back.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if dormantCount > 0 {
                Label(dormantCount == 1 ? "One repo hasn't been touched in 6 months or more, so it starts unchecked." : "\(dormantCount) repos haven't been touched in 6 months or more, so they start unchecked.", systemImage: "moon.zzz")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if app.grouping.other.count >= 2 {
                HStack(spacing: 8) {
                    Label("\(app.grouping.other.count) repos didn't fit a project.", systemImage: "tray")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SuggestGroupsButton()
                        .controlSize(.small)
                        .font(.callout)
                }
            }
            HStack(spacing: 8) {
                if total > Self.filterThreshold {
                    TextField("Filter", text: $filter, prompt: Text("Filter repositories"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                Spacer()
                Button("Select All") { set(shown, checked: true) }
                    .disabled(shown.allSatisfy { !unchecked.contains($0) })
                Button("Deselect All") { set(shown, checked: false) }
                    .disabled(shown.allSatisfy { unchecked.contains($0) })
            }
            List(selection: $highlighted) {
                ForEach(sections) { section in
                    SwiftUI.Section {
                        ForEach(section.repos) { entry in
                            row(entry).tag(entry.id)
                        }
                    } header: {
                        header(section)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(minHeight: 160, maxHeight: .infinity)
            .onKeyPress(.space) {
                toggleHighlighted()
                return .handled
            }
            .overlay {
                if sections.isEmpty { ContentUnavailableView.search(text: filter) }
            }
            HStack {
                Button("Back", action: onBack)
                Spacer()
                Text("\(selectedCount) of \(total) selected")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(selectedCount)))
                    .animation(Motion.smooth, value: selectedCount)
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCount == 0)
                    .help(selectedCount == 0 ? "Choose at least one repository" : "")
            }
        }
    }

    /// Project name with a checkbox for all its (shown) repos: mixed when some are unchecked.
    private func header(_ section: Section) -> some View {
        Toggle(sources: section.repos.map { isChecked($0.id) }, isOn: \.self) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.name).font(.headline).foregroundStyle(.primary)
                Text(section.why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityHint("Checks or unchecks every repository in \(section.name)")
    }

    private func row(_ entry: RepoEntry) -> some View {
        let dormant = AppModel.isDormant(entry)
        return HStack(spacing: 8) {
            Toggle(isOn: isChecked(entry.id)) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
            }
            .toggleStyle(.checkbox)
            if let extra = extras(entry) {
                Text(extra).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let activity = activityText(entry, dormant: dormant) {
                Text(activity)
                    .font(.callout)
                    .foregroundStyle(dormant ? .secondary : .tertiary)
                    .lineLimit(1)
                    .help("Last commit, checkout or staged change")
            }
        }
        .help((entry.primary.url.path as NSString).abbreviatingWithTildeInPath)
    }

    /// "2 copies · 3 worktrees" — they follow the repo when it's hidden.
    private func extras(_ entry: RepoEntry) -> String? {
        let worktrees = entry.copies.reduce(0) { $0 + $1.worktrees.count }
        let parts = [
            entry.hasDuplicates ? "\(entry.copies.count) copies" : nil,
            worktrees > 0 ? "\(worktrees) worktree\(worktrees == 1 ? "" : "s")" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "3 weeks ago", or "untouched since Mar 2025" once it's dormant.
    private func activityText(_ entry: RepoEntry, dormant: Bool) -> String? {
        guard let date = entry.lastActivity else { return nil }
        if dormant { return "untouched since \(date.formatted(.dateTime.month(.abbreviated).year()))" }
        return date.formatted(.relative(presentation: .named))
    }

    private func isChecked(_ id: RepoID) -> Binding<Bool> {
        Binding {
            !unchecked.contains(id)
        } set: { checked in
            if checked { unchecked.remove(id) } else { unchecked.insert(id) }
        }
    }

    private func set(_ ids: [RepoID], checked: Bool) {
        if checked { unchecked.subtract(ids) } else { unchecked.formUnion(ids) }
    }

    /// Space: check the highlighted rows, or uncheck them if they're all checked (Finder's rule).
    private func toggleHighlighted() {
        guard !highlighted.isEmpty else { return }
        let allChecked = highlighted.allSatisfy { !unchecked.contains($0) }
        set(Array(highlighted), checked: !allChecked)
    }
}

/// Last step: optional AI key and menu bar. Both skippable, both in Settings later.
private struct OnboardingExtras: View {
    var onDone: () -> Void
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 16) {
            Text("Two optional extras")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("AI commit messages", systemImage: "sparkles").font(.headline)
                Text("Paste an OpenAI API key and the ✨ button writes a message from what you're about to commit. The key is stored in your Keychain; files that look like secrets are never sent.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if app.hasAIKey {
                    Label("Key saved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    SecureField("OpenAI API key (optional)", text: $key, prompt: Text("sk-…"))
                        .textFieldStyle(.roundedBorder)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $settings.showMenuBarExtra) {
                    Label("Show Ferry in the menu bar", systemImage: "menubar.rectangle").font(.headline)
                }
                Text("A quick list of repos that need you, even with the window closed.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Start Using Ferry", action: finish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finish() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            do {
                try app.saveAIKey(trimmed)
            } catch {
                self.error = "Couldn't save the key: \(error.localizedDescription). You can add it later in Settings → AI."
                return
            }
        }
        onDone()
    }
}

/// A folder offered in onboarding. Only folders directly in the home folder are probed —
/// that never triggers a macOS privacy prompt; Documents and Desktop are offered with a note.
struct FolderChoice: Identifiable, Hashable {
    var url: URL
    var isOn: Bool
    var note: String?
    var id: URL { url }

    var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }

    static let likelyNames = ["Developer", "Projects", "projects", "Code", "code", "src", "dev", "Dev", "repos", "Repos", "git", "GitHub", "github", "workspace", "Workspace", "work", "Sites", "ghq"]

    static func suggestions(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [FolderChoice] {
        #if DEBUG
        // Screenshot/test runs: `-FerryOnboardingFolders /a:/b` replaces the suggestions.
        if let override = UserDefaults.standard.string(forKey: "FerryOnboardingFolders") {
            return override.split(separator: ":").map { FolderChoice(url: URL(fileURLWithPath: String($0)), isOn: true) }
        }
        #endif
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [FolderChoice] = []
        for name in likelyNames {
            let url = home.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            // Case-insensitive volumes report both "Code" and "code"; keep the first.
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  seen.insert(name.lowercased()).inserted else { continue }
            result.append(FolderChoice(url: url, isOn: true))
        }
        let protected = "macOS will ask to let Ferry read this folder."
        result.append(FolderChoice(url: home.appendingPathComponent("Documents", isDirectory: true), isOn: result.isEmpty, note: protected))
        result.append(FolderChoice(url: home.appendingPathComponent("Desktop", isDirectory: true), isOn: false, note: protected))
        return result
    }
}
