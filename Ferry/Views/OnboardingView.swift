import SwiftUI
import AppKit
import FerryKit

/// First run: welcome → choose folders → live scan → review projects → extras.
/// Every macOS permission prompt is explained before the choice that causes it.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, folders, scanning, review, extras
    }

    @Environment(AppModel.self) private var app
    @State private var step: Step = .welcome
    @State private var choices: [FolderChoice] = FolderChoice.suggestions()
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .folders: folders
                case .scanning: scanning
                case .review: review
                case .extras: OnboardingExtras { app.finishOnboarding() }
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
        let roots = choices.filter(\.isOn).map(\.url)
        scanTask = Task {
            await app.startOnboardingScan(roots: roots)
            guard !Task.isCancelled else { return }
            step = .review
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
                    scanTask?.cancel()
                    step = .review
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
                Text("Here's how Ferry grouped them")
                    .font(.title2.weight(.semibold))
                Text("Right-click a project to rename it, or use a repo's … menu to move or hide it — any time.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(app.grouping.projects) { project in
                            ReviewCard(name: project.name, why: project.why, repos: project.repos)
                        }
                        if !app.grouping.other.isEmpty {
                            ReviewCard(name: Grouping.otherTitle, why: Grouping.otherWhy, repos: app.grouping.other)
                        }
                    }
                }
                .frame(maxHeight: 340)
                HStack {
                    Button("Back") { step = .folders }
                    Spacer()
                    Button("Continue") { step = .extras }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

private struct ReviewCard: View {
    var name: String
    var why: String
    var repos: [RepoEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.headline)
                Text("\(repos.count) repo\(repos.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Spacer()
            }
            Text(why).font(.caption).foregroundStyle(.secondary)
            Text(repos.map { $0.hasDuplicates ? "\($0.name) (\($0.copies.count) copies)" : $0.name }.joined(separator: ", "))
                .font(.callout)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
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
