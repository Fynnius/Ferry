import SwiftUI
import FerryKit

/// The main window: whatever the app's phase needs — setup problems, first run, or the fleet.
struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch app.phase {
            case .starting:
                ProgressView("Getting ready…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .gitUnavailable(let message):
                GitUnavailableView(message: message)
            case .onboarding:
                OnboardingView()
            case .ready:
                FleetView()
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .task {
            // Under XCTest the app is only a test host; never touch saved folders.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            await app.start()
        }
        .onAppear {
            GlobalHotKey.shared.action = { [openWindow] in
                openWindow(id: "main")
                NSApp.activate()
            }
            GlobalHotKey.shared.setEnabled(app.settings.globalHotKeyEnabled)
        }
        .alert(
            app.confirmation?.title ?? "",
            isPresented: .init(get: { app.confirmation != nil }, set: { if !$0 { app.confirmation = nil } }),
            presenting: app.confirmation
        ) { confirmation in
            Button(confirmation.confirmTitle) { confirmation.action() }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .dialogSuppressionToggle("Don't ask again for this repo", isSuppressed: suppression)
        .modifier(NamePrompts())
    }

    private var suppression: Binding<Bool> {
        Binding {
            guard let id = app.confirmation?.suppressionRepoID else { return false }
            return app.settings.protectedBranchConfirmationSkipped.contains(id)
        } set: { suppressed in
            guard let id = app.confirmation?.suppressionRepoID else { return }
            if suppressed {
                app.settings.protectedBranchConfirmationSkipped.insert(id)
            } else {
                app.settings.protectedBranchConfirmationSkipped.remove(id)
            }
        }
    }
}

/// Text prompts for naming projects (new project from a repo's menu, rename from the sidebar).
struct NamePrompts: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("New Project", isPresented: .init(get: { app.newProjectRequest != nil }, set: { if !$0 { app.newProjectRequest = nil } })) {
                TextField("Project name", text: $name)
                Button("Create") {
                    if let repo = app.newProjectRequest { app.moveToNewProject(repo, named: name) }
                    name = ""
                }
                Button("Cancel", role: .cancel) { name = "" }
            } message: {
                Text("\(app.newProjectRequest?.name ?? "The repo") moves into it. Ferry remembers this across rescans.")
            }
            .alert("Rename Project", isPresented: .init(get: { app.renameRequest != nil }, set: { if !$0 { app.renameRequest = nil } })) {
                TextField("Project name", text: $name)
                Button("Rename") {
                    if let project = app.renameRequest { app.renameProject(project, to: name) }
                    name = ""
                }
                Button("Cancel", role: .cancel) { name = "" }
            }
            .onChange(of: app.renameRequest?.id) { name = app.renameRequest?.name ?? "" }
    }
}

/// Layout C: projects in the sidebar, the selection's repos stacked on the right.
struct FleetView: View {
    @Environment(AppModel.self) private var app
    @State private var visibility = NavigationSplitViewVisibility.automatic
    @State private var collapsedForWidth = false
    @State private var historyHiddenForWidth = false
    @FocusState private var searchFocused: Bool

    /// Below `collapseWidth` the sidebar hides itself, leaving the stack — the VS Code-
    /// sidebar size people run Ferry at — and returns above `restoreWidth`. The gap keeps
    /// it from flapping at one width.
    nonisolated static let collapseWidth: CGFloat = 620
    nonisolated static let restoreWidth: CGFloat = 700

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView()
                .folderDropTarget()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            RepoStackView()
                .folderDropTarget(cornerRadius: Metrics.cardCorner, inset: 8)
                .inspector(isPresented: $app.showsHistory) {
                    HistoryInspector()
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
                }
        }
        .onChange(of: visibility, initial: true) { _, value in
            app.isSidebarHidden = value == .detailOnly
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            // Changing column visibility inside a layout pass makes AppKit's split view
            // re-enter constraint updates and abort; apply it on the next run loop turn.
            DispatchQueue.main.async { adaptSidebar(toWidth: width) }
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Filter repos")
        .searchFocused($searchFocused)
        .onChange(of: app.focusSearchCount) { searchFocused = true }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await app.fetchAll() }
                } label: {
                    Label("Fetch All", systemImage: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, isActive: app.isFetchingAll && !Motion.reduceMotion)
                }
                .help(fetchAllHelp)
                .disabled(app.isFetchingAll)
                if app.isOffline {
                    Label("Offline", systemImage: "wifi.slash")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .help("You're offline. Committing works; fetching, pulling and pushing wait until you're back online.")
                }
                if app.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .help("Looking for repositories…")
                }
                Button {
                    app.showsHistory.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .help("Show the current repo's history (⌥⌘H)")
            }
        }
    }
}

extension FleetView {
    /// The oldest fetch across the fleet, so "all clear" can be trusted at a glance.
    fileprivate var fetchAllHelp: String {
        let dates = app.allRepos.filter { $0.status?.hasRemote == true }.map(\.lastFetchedAt)
        guard !dates.isEmpty else { return "Fetch every repo now (⌥⌘⇧F)" }
        if dates.contains(where: { $0 == nil }) { return "Fetch every repo now (⌥⌘⇧F) · some repos not fetched yet" }
        let oldest = dates.compactMap { $0 }.min()!
        return "Fetch every repo now (⌥⌘⇧F) · oldest fetch \(oldest.formatted(.relative(presentation: .named)))"
    }

    fileprivate func adaptSidebar(toWidth width: CGFloat) {
        if width < Self.collapseWidth {
            // The stack is what matters at this size; sidebar and History make room.
            if visibility != .detailOnly {
                collapsedForWidth = true
                withAnimation(Motion.snappy) { visibility = .detailOnly }
            }
            if app.showsHistory {
                historyHiddenForWidth = true
                app.showsHistory = false
            }
        } else if width > Self.restoreWidth {
            if collapsedForWidth {
                collapsedForWidth = false
                withAnimation(Motion.snappy) { visibility = .automatic }
            }
            if historyHiddenForWidth {
                historyHiddenForWidth = false
                app.showsHistory = true
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section {
                SidebarRow(title: "Needs Attention", symbol: "exclamationmark.circle", count: app.attentionCount)
                    .tag(SidebarItem.attention)
                SidebarRow(title: "All Repositories", symbol: "square.stack.3d.up", count: nil)
                    .tag(SidebarItem.all)
            }
            Section("Projects") {
                ForEach(app.projects) { project in
                    SidebarRow(title: project.name, symbol: project.isOther ? "tray" : "folder", count: project.attentionCount > 0 ? project.attentionCount : nil)
                        .tag(SidebarItem.project(project.id))
                        .help(project.reason ?? project.name)
                        .contextMenu {
                            if !project.isOther {
                                Button("Rename…") { app.renameRequest = project }
                            }
                            if let reason = project.reason {
                                Text(reason)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int?

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let count {
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(count.map { "\($0) need attention" } ?? "")
    }
}

/// The stack: repos that need you first (open), then the rest as quiet one-liners.
/// ↑/↓ move between cards, ↩ jumps into the card's message field.
struct RepoStackView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focusedCard: String?

    var body: some View {
        let entries = app.entries(for: app.selection)
        let order = (entries.active + entries.quiet).map(\.id)
        let collapsed = app.collapsedRepoIDs(in: entries.active.map(\.repo))
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                if let warning = app.shellWarning {
                    NoticeRow(symbol: "terminal", text: warning) { app.shellWarning = nil }
                }
                if let notice = app.fleetNotice {
                    NoticeRow(symbol: "sparkle.magnifyingglass", text: notice) { app.fleetNotice = nil }
                }
                ForEach(entries.active) { entry in
                    card(entry, collapsed: collapsed.contains(entry.id))
                }
                if !entries.quiet.isEmpty {
                    Text("Up to date")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, entries.active.isEmpty ? 0 : 10)
                        .padding(.leading, 4)
                    // Quiet repos read as one grouped list, not a card per row.
                    VStack(spacing: 0) {
                        ForEach(entries.quiet) { entry in
                            card(entry)
                            if entry.id != entries.quiet.last?.id {
                                Divider().padding(.leading, Metrics.cardPadding)
                            }
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardCorner))
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner))
                }
            }
            .padding(16)
            .animation(Motion.snappy, value: entries.active.map(\.id))
            .animation(Motion.snappy, value: collapsed)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: collapsed) { _, _ in
            // Cards opening or folding can push the current repo out of view; bring it back.
            guard let id = app.currentRepoID else { return }
            withAnimation(Motion.snappy) { proxy.scrollTo(id, anchor: .top) }
        }
        .onChange(of: app.scrollTarget) { _, id in
            guard let id else { return }
            withAnimation(Motion.snappy) { proxy.scrollTo(id, anchor: .top) }
            app.scrollTarget = nil
        }
        .onChange(of: app.focusCardRequest) { _, id in
            guard let id else { return }
            app.focusCardRequest = nil
            focusedCard = id
            // The lazy stack may only draw the card once the scroll reaches it.
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if app.currentRepoID == id, focusedCard != id { focusedCard = id }
            }
        }
        .onKeyPress(.downArrow) { move(1, in: order, proxy: proxy) }
        .onKeyPress(.upArrow) { move(-1, in: order, proxy: proxy) }
        .onChange(of: focusedCard) { _, id in
            if let id { app.currentRepoID = id }
        }
        }
        .overlay {
            if entries.active.isEmpty && entries.quiet.isEmpty {
                emptyState
            }
        }
        .navigationTitle(app.title(for: app.selection))
        .navigationSubtitle(subtitle)
    }

    private func card(_ entry: StackEntry, collapsed: Bool = false) -> some View {
        RepoSection(repo: entry.repo, projectCaption: caption(for: entry), isCollapsed: collapsed)
            .focusable()
            .focusEffectDisabled()
            .focused($focusedCard, equals: entry.id)
            .onKeyPress(.return) {
                entry.repo.focusMessageCount += 1
                return entry.repo.status?.hasChanges == true ? .handled : .ignored
            }
            .id(entry.id)
            .transition(.repoRise)
    }

    private func move(_ step: Int, in order: [String], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let current = focusedCard.flatMap { order.firstIndex(of: $0) } ?? (step > 0 ? -1 : order.count)
        let next = min(max(current + step, 0), order.count - 1)
        focusedCard = order[next]
        withAnimation(Motion.snappy) { proxy.scrollTo(order[next], anchor: .center) }
        return .handled
    }

    private func caption(for entry: StackEntry) -> String? {
        app.settings.privacyMode ? nil : entry.projectName
    }

    /// Scoped to what's selected, and never repeating the sidebar's own count.
    private var subtitle: String {
        func repos(_ n: Int) -> String { n == 1 ? "1 repo" : "\(n) repos" }
        switch app.selection {
        case .project(let id):
            let project = app.projects.first { $0.id == id }
            let total = project?.repos.count ?? 0
            let attention = project?.attentionCount ?? 0
            return attention == 0 ? "\(repos(total)), all clear" : "\(attention) of \(repos(total)) need you"
        case .all:
            return app.attentionCount == 0 ? "All clear" : "\(app.attentionCount) need you"
        case .attention, nil:
            // The sidebar badge already shows the count; repeat it only when it's hidden.
            if app.isSidebarHidden, app.attentionCount > 0 { return "\(app.attentionCount) of \(repos(app.allRepos.count)) need you" }
            return repos(app.allRepos.count)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !app.searchText.isEmpty {
            ContentUnavailableView.search(text: app.searchText)
        } else if app.selection == .attention {
            ContentUnavailableView {
                Label("All clear", systemImage: "checkmark.circle")
            } description: {
                Text("Nothing to commit, push or pull in any repo.")
            } actions: {
                Button("Show All Repositories") { app.selection = .all }
            }
        } else {
            ContentUnavailableView("No repositories", systemImage: "folder", description: Text("Add a folder that contains git repos in Settings → Folders."))
        }
    }
}

/// A dismissible one-line notice above the stack.
struct NoticeRow: View {
    var symbol: String
    var text: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Git missing or unusable: say what to do, offer to retry.
struct GitUnavailableView: View {
    var message: String
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("Ferry needs git", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            HStack {
                Button("Install Command Line Tools") {
                    Task {
                        _ = try? await Subprocess.run(SubprocessRequest(executable: URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["--install"]))
                    }
                }
                Button("Try Again") { Task { await app.start() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
