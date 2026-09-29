import SwiftUI
import ServiceManagement
import FerryKit

/// Settings window (HIG: toolbar of panes, few options, ⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            // Each pane has its own height; the window resizes between them like System Settings panes.
            Tab("General", systemImage: "gearshape") { GeneralSettings().frame(height: 540) }
            Tab("Folders", systemImage: "folder") { FolderSettings().frame(height: 500) }
            Tab("Git", systemImage: "arrow.triangle.branch") { GitSettings().frame(height: 600) }
            Tab("AI", systemImage: "sparkles") { AISettings().frame(height: 250) }
        }
        .frame(width: 540)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmsSetup = false

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Fetch in the background", isOn: $settings.autoFetch)
                Picker("Every", selection: $settings.fetchIntervalMinutes) {
                    ForEach([1, 3, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                .disabled(!settings.autoFetch)
            } footer: {
                Text("Keeps ↑/↓ counts current. Skipped while offline or in Low Power Mode.")
                    .foregroundStyle(.secondary)
            }
            Section("Open with") {
                Picker("Editor", selection: $settings.editorBundleID) {
                    Text("Default app for each file").tag("")
                    ForEach(Opener.knownEditors.filter { Opener.isInstalled($0.bundleID) }, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
                Picker("Terminal", selection: $settings.terminalBundleID) {
                    ForEach(Opener.knownTerminals.filter { Opener.isInstalled($0.bundleID) }, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
            }
            Section {
                Toggle("Show in menu bar", isOn: $settings.showMenuBarExtra)
                Toggle("Show count on Dock icon", isOn: $settings.showDockBadge)
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Toggle("Bring Ferry forward with \(GlobalHotKey.displayString)", isOn: $settings.globalHotKeyEnabled)
                Toggle("Hide repo names (for screen sharing)", isOn: $settings.privacyMode)
            } footer: {
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("Setup") {
                    Button("Run Setup Again…") { confirmsSetup = true }
                }
            } footer: {
                Text("Choose folders and repositories from scratch. Your preferences and OpenAI key stay.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Run setup again?", isPresented: $confirmsSetup) {
            Button("Run Setup Again", role: .destructive) {
                app.runSetupAgain()
                openWindow(id: "main")
                NSApp.activate()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ferry forgets its folders and how you organised the repos — hidden and pinned repos, project names and moves, snoozes — and shows setup. Nothing in your repositories changes. Your preferences and OpenAI key stay.")
        }
        .onChange(of: settings.globalHotKeyEnabled) { _, enabled in GlobalHotKey.shared.setEnabled(enabled) }
        .onChange(of: settings.autoFetch) { app.fetchSettingsChanged() }
        .onChange(of: settings.fetchIntervalMinutes) { app.fetchSettingsChanged() }
    }
}

struct FolderSettings: View {
    @Environment(AppModel.self) private var app
    @State private var selection: ScanRoot?

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(app.discovery.roots, id: \.self) { root in
                        Label((root.url.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(root.url.path)
                            .tag(root)
                    }
                }
                .frame(minHeight: 120)
                HStack {
                    Button("Add Folder…") { app.addFolders() }
                    Button("Remove") {
                        if let selection { app.removeRoot(selection) }
                        selection = nil
                    }
                    .disabled(selection == nil)
                    Spacer()
                    if app.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Button("Rescan Now") { Task { await app.rescan() } }
                        .disabled(app.isScanning)
                }
                SuggestGroupsButton()
            } header: {
                Text("Folders to scan")
            } footer: {
                Text("Ferry looks up to 6 folders deep and skips dependency and build folders. Repos you add or move yourself are remembered across rescans.")
                    .foregroundStyle(.secondary)
            }
            Section("Hidden repositories") {
                if app.grouping.hidden.isEmpty {
                    Text("None. Hide a repo from its … menu.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.grouping.hidden) { entry in
                        HStack {
                            Text(entry.name)
                            Text((entry.primary.url.path as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Show") { app.unhide(entry.id) }
                        }
                    }
                }
                Button("Add a Repository Directly…") { app.addRepositoryManually() }
            }
        }
        .formStyle(.grouped)
    }
}

struct GitSettings: View {
    @Environment(AppModel.self) private var app
    @State private var newBranch = ""
    @State private var github = GitHubConnection()

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                GitHubSignInDetail(connection: github, prominent: false)
            } header: {
                Text("GitHub sign-in")
            } footer: {
                Text("For repos that use GitHub over HTTPS. SSH remotes (git@github.com:…) sign in with your SSH keys instead.")
                    .foregroundStyle(.secondary)
            }
            .task { await github.load(app) }
            Section {
                Picker("When pulling diverged branches", selection: $settings.pullStrategy) {
                    Text("Merge").tag(GitRepository.PullStrategy.merge)
                    Text("Rebase").tag(GitRepository.PullStrategy.rebase)
                }
            } footer: {
                Text("Only used when your git config doesn't set pull.rebase or pull.ff — your config always wins.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(settings.protectedBranches, id: \.self) { branch in
                    HStack {
                        Label(branch, systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") {
                            settings.protectedBranches.removeAll { $0 == branch }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add branch", text: $newBranch)
                        .onSubmit(addBranch)
                    Button("Add", action: addBranch)
                        .disabled(newBranch.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !settings.protectedBranchConfirmationSkipped.isEmpty {
                    Button("Ask Again in All Repos") { settings.protectedBranchConfirmationSkipped = [] }
                }
            } header: {
                Text("Protected branches")
            } footer: {
                Text("Ferry asks once per session before you commit to these, and marks them when work is headed there. It never blocks.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Git executable", text: $settings.gitPath, prompt: Text(app.runner?.executable.path ?? "Automatic"))
                if let version = app.runner?.installation.version {
                    LabeledContent("Using", value: "git \(version.description)")
                }
            } footer: {
                Text("Leave empty to use the git from your shell's PATH. Changes apply after restarting Ferry.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addBranch() {
        let name = newBranch.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !app.settings.protectedBranches.contains(name) else { return }
        app.settings.protectedBranches.append(name)
        newBranch = ""
    }
}

struct AISettings: View {
    @Environment(AppModel.self) private var app
    @State private var newKey = ""
    @State private var keyError: String?

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                if app.hasAIKey {
                    LabeledContent("OpenAI API key") {
                        HStack {
                            Label("Saved in Keychain", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Button("Remove") {
                                do { try app.removeAIKey() } catch { keyError = error.localizedDescription }
                            }
                        }
                    }
                } else {
                    LabeledContent("OpenAI API key") {
                        HStack {
                            SecureField("OpenAI API key", text: $newKey, prompt: Text("sk-…"))
                                .labelsHidden()
                                .frame(minWidth: 240)
                                .onSubmit(saveKey)
                            Button("Save", action: saveKey)
                                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    Link("Get a key at platform.openai.com", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.callout)
                }
                if let keyError {
                    Text(keyError).foregroundStyle(.red)
                }
                TextField("Model", text: $settings.aiModel)
            } footer: {
                Text(AppModel.aiPrivacyText)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func saveKey() {
        do {
            try app.saveAIKey(newKey)
            newKey = ""
            keyError = nil
        } catch {
            keyError = "Couldn't save the key: \(error.localizedDescription)"
        }
    }
}
