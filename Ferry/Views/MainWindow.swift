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
                // Wide enough for "Needs Attention" and a two-digit count at the minimum.
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
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
    @State private var showsGroupSuggestions = false

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
                            } else if AppleIntelligence.isAvailable {
                                Button("Suggest Groups…") { showsGroupSuggestions = true }
                                    .disabled(project.repos.count < 2)
                            } else if let reason = AppleIntelligence.unavailableReason {
                                Text(reason)
                            }
                            if let reason = project.reason {
                                Text(reason)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $showsGroupSuggestions) { GroupSuggestionsSheet() }
        // The same soft edge under the toolbar as the stack and History, never a hard line.
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int?

    var body: some View {
        // The system sidebar badge: laid out so the title keeps its room, and hidden at 0.
        Label(title, systemImage: symbol)
            .badge(count ?? 0)
            .accessibilityElement(children: .combine)
        .accessibilityValue(count.map { "\($0) need attention" } ?? "")
    }
}

/// The stack: one full-width list per group of what repos need next — Needs a Fix,
/// Changes, Ready to Push, Not Published, Updates Available, Dormant (folded), Up to Date —
/// each row lined up in the same columns. A repo with changes opens in place under its row.
/// ↑/↓ move between repos, ←/→ fold and open one, ↩ jumps into its message field.
struct RepoStackView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focusedCard: String?
    @State private var showsDormant = false
    @State private var columns: StackColumns?

    var body: some View {
        let sections = app.entries(for: app.selection)
        let drawnGroups = sections.groups.filter { $0.urgency != .dormant || showsDormant }
        let order = drawnGroups.flatMap(\.entries).map(\.id)
        let collapsed = app.collapsedRepoIDs(in: sections.repos)
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let warning = app.shellWarning {
                    NoticeRow(symbol: "terminal", text: warning) { app.shellWarning = nil }
                }
                if let notice = app.fleetNotice {
                    NoticeRow(symbol: "sparkle.magnifyingglass", text: notice) { app.fleetNotice = nil }
                }
                SignInNotices()
                if app.selection == .attention, !sections.needsYou, !sections.isEmpty, app.searchText.isEmpty {
                    allClear(sections)
                }
                ForEach(sections.groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        groupHeader(group)
                        if group.urgency != .dormant || showsDormant {
                            groupList(group, collapsed: collapsed)
                        }
                    }
                }
            }
            .padding(Metrics.stackMargin)
            .animation(Motion.snappy, value: order)
            .animation(Motion.snappy, value: collapsed)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            columns = StackColumns.forRowWidth(width - 2 * Metrics.stackMargin - 2 * Metrics.rowPadding)
        }
        .onChange(of: collapsed) { _, _ in
            // Rows opening or folding can push the current repo out of view; bring it back.
            guard let id = app.currentRepoID else { return }
            withAnimation(Motion.snappy) { proxy.scrollTo(id, anchor: .top) }
        }
        .onChange(of: app.currentRepoID.flatMap { order.firstIndex(of: $0) }) { old, new in
            // The repo just worked in moved (a commit made it "ready to push"): keep it in view.
            guard old != nil, new != nil, let id = app.currentRepoID else { return }
            withAnimation(Motion.snappy) { proxy.scrollTo(id) }
        }
        .onChange(of: app.scrollTarget) { _, id in
            guard let id else { return }
            if sections.group(.dormant).contains(where: { $0.id == id }) { showsDormant = true }
            withAnimation(Motion.snappy) { proxy.scrollTo(id, anchor: .top) }
            app.scrollTarget = nil
        }
        .onChange(of: app.focusCardRequest) { _, id in
            guard let id else { return }
            app.focusCardRequest = nil
            focusedCard = id
            // The lazy stack may only draw the row once the scroll reaches it.
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
        .environment(\.stackColumns, columns)
        .overlay {
            if sections.isEmpty {
                emptyState
            }
        }
        .navigationTitle(app.title(for: app.selection))
        .navigationSubtitle(subtitle(sections))
    }

    /// The group's symbol in its status colour, title and count. Dormant folds.
    @ViewBuilder
    private func groupHeader(_ group: StackGroup) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: group.urgency.symbol)
                .foregroundStyle(group.urgency.tint)
                .accessibilityHidden(true)
            Text(group.urgency.title)
                .font(.headline)
            Text("\(group.entries.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(group.entries.count)))
        }
        .padding(.leading, 4)
        if group.urgency == .dormant {
            Button {
                Motion.animate { showsDormant.toggle() }
            } label: {
                HStack(spacing: 6) {
                    label
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsDormant ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Changes nobody has touched for six months or more. They don't count as needing you.")
            .accessibilityLabel("Dormant, \(group.entries.count) repos, \(showsDormant ? "expanded" : "collapsed")")
        } else {
            label
                .help(groupHelp(group.urgency))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func groupHelp(_ urgency: RepoUrgency) -> String {
        switch urgency {
        case .problem: "Conflicts, an unfinished merge or rebase, or something that failed"
        case .changes: "Uncommitted work"
        case .readyToPush: "Committed, not pushed yet"
        case .unpublished: "Branches with commits that aren't on the remote"
        case .behind: "Only a pull to do; they don't count as needing you"
        case .dormant: ""
        case .clear: "Nothing to do"
        }
    }

    /// One rounded list per group, rows divided by hairlines inset to the names.
    private func groupList(_ group: StackGroup, collapsed: Set<String>) -> some View {
        VStack(spacing: 0) {
            ForEach(group.entries) { entry in
                row(entry, collapsed: collapsed.contains(entry.id))
                if entry.id != group.entries.last?.id {
                    Divider().padding(.leading, Metrics.rowPadding + RepoHeader.contentInset)
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardCorner))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner))
    }

    /// Needs Attention with nothing that needs you, but updates or dormant work below:
    /// say it's clear, and what the rest is.
    private func allClear(_ sections: StackSections) -> some View {
        var parts: [String] = []
        let updates = sections.group(.behind).count, dormant = sections.group(.dormant).count
        if updates > 0 { parts.append(updates == 1 ? "1 repo has updates to pull." : "\(updates) repos have updates to pull.") }
        if dormant > 0 { parts.append(dormant == 1 ? "1 repo has changes nobody touched in months." : "\(dormant) repos have changes nobody touched in months.") }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing needs you").font(.headline)
                Text(parts.joined(separator: " "))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func row(_ entry: StackEntry, collapsed: Bool) -> some View {
        let repo = entry.repo
        return RepoSection(repo: repo, projectCaption: caption(for: entry), isCollapsed: collapsed)
            .focusable()
            .focusEffectDisabled()
            .focused($focusedCard, equals: repo.id)
            .onKeyPress(.return) {
                repo.focusMessageCount += 1
                return repo.status?.hasChanges == true ? .handled : .ignored
            }
            // Finder outline keys: → opens a folded repo, ← folds an open one.
            .onKeyPress(.rightArrow) {
                guard repo.status?.hasChanges == true, collapsed else { return .ignored }
                app.setFolded(repo, false)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard repo.status?.hasChanges == true, !collapsed else { return .ignored }
                app.setFolded(repo, true)
                return .handled
            }
            .id(repo.id)
            .transition(.opacity)
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

    /// Scoped to what's selected, never repeating the sidebar's own count, and only
    /// counting what the list can show (a worktree isn't a repo of its own here).
    private func subtitle(_ sections: StackSections) -> String {
        func repos(_ n: Int) -> String { n == 1 ? "1 repo" : "\(n) repos" }
        switch app.selection {
        case .project(let id):
            let project = app.projects.first { $0.id == id }
            let total = project?.repos.filter { $0.worktreeOf == nil }.count ?? 0
            let attention = project?.attentionCount ?? 0
            return attention == 0 ? "\(repos(total)), all clear" : "\(attention) of \(repos(total)) need you"
        case .all:
            return app.attentionCount == 0 ? "All clear" : "\(app.attentionCount) need you"
        case .attention, nil:
            // The count itself is the sidebar badge, repeated here only while it's hidden.
            return app.isSidebarHidden && app.attentionCount > 0 ? "\(app.attentionCount) need you" : ""
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
