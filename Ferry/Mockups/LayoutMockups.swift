#if DEBUG
import SwiftUI
import FerryKit

/// Layout candidates for the main window, built from the real repo components with sample data.
/// Launch with `-FerryMockup A|B|C` (see scripts/render-mockups.sh).
enum MockupLayout: String {
    case a = "A", b = "B", c = "C", des6 = "D6"
}

struct MockupRoot: View {
    let layout: MockupLayout
    let narrow: Bool
    @State private var projects = SampleData.projects()

    var body: some View {
        Group {
            switch layout {
            case .a: FlatStackMockup(projects: projects)
            case .b: SidebarDetailMockup(projects: projects, narrow: narrow)
            case .c: HybridMockup(projects: projects, narrow: narrow)
            case .des6: DES6Board()
            }
        }
        .frame(width: layout == .des6 ? 1880 : narrow ? 420 : 1080, height: layout == .des6 ? 900 : 760)
    }
}

// MARK: - A: one scroll, every repo stacked (VS Code refined)

struct FlatStackMockup: View {
    let projects: [ProjectItem]
    @State private var filter = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                    ForEach(projects) { project in
                        ProjectHeading(project: project)
                        ForEach(project.repos) { repo in
                            RepoSection(repo: repo)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Ferry")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $filter) {
                        Text("Needs Attention").tag(0)
                        Text("All").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItemGroup {
                    Button("Fetch All", systemImage: "arrow.triangle.2.circlepath") {}
                }
            }
        }
    }
}

struct ProjectHeading: View {
    let project: ProjectItem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(project.name).font(.title3.weight(.semibold))
            Text("\(project.repos.count) repos").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
    }
}

// MARK: - B: sidebar of projects and repos, one repo in the detail

struct SidebarDetailMockup: View {
    let projects: [ProjectItem]
    let narrow: Bool
    @State private var selection: String?
    @State private var visibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: $selection) {
                ForEach(projects) { project in
                    Section(project.name) {
                        ForEach(project.repos) { repo in
                            SidebarRepoRow(repo: repo).tag(repo.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let repo = projects.flatMap(\.repos).first(where: { $0.id == selection }) {
                ScrollView {
                    RepoSection(repo: repo)
                        .padding(16)
                }
                .navigationTitle(repo.name)
            }
        }
        .onAppear {
            selection = projects.first?.repos.first?.id
            if narrow { visibility = .detailOnly }
        }
    }
}

struct SidebarRepoRow: View {
    let repo: RepoItem

    var body: some View {
        HStack {
            Label(repo.name, systemImage: "shippingbox")
            Spacer()
            if let status = repo.status {
                if status.hasChanges {
                    Text("\(status.changedPathCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if case .upToDate = status.syncState {
                } else {
                    SyncChip(state: status.syncState)
                        .font(.caption)
                        .labelStyle(.compactIcon)
                }
            }
        }
    }
}

// MARK: - C: projects in the sidebar, the selection's repos stacked on the right

struct HybridMockup: View {
    let projects: [ProjectItem]
    let narrow: Bool
    @State private var selection: String? = "attention"
    @State private var visibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: $selection) {
                Section {
                    SidebarItemRow(title: "Needs Attention", symbol: "exclamationmark.circle", count: attentionRepos.count)
                        .tag("attention")
                    SidebarItemRow(title: "All Repositories", symbol: "square.stack.3d.up", count: nil)
                        .tag("all")
                }
                Section("Projects") {
                    ForEach(projects) { project in
                        SidebarItemRow(title: project.name, symbol: "folder", count: project.attentionCount > 0 ? project.attentionCount : nil)
                            .tag(project.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                    ForEach(visibleRepos, id: \.repo.id) { entry in
                        RepoSection(repo: entry.repo, projectCaption: entry.caption)
                    }
                    if !quietRepos.isEmpty {
                        Text("Up to date")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                            .padding(.leading, 4)
                        ForEach(quietRepos, id: \.repo.id) { entry in
                            RepoSection(repo: entry.repo, projectCaption: entry.caption)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup {
                    Button("Fetch All", systemImage: "arrow.triangle.2.circlepath") {}
                    Button("Filter", systemImage: "line.3.horizontal.decrease") {}
                }
            }
        }
        .onAppear { if narrow { visibility = .detailOnly } }
    }

    private var attentionRepos: [RepoItem] { projects.flatMap(\.repos).filter(\.needsAttention) }

    private var entries: [(repo: RepoItem, caption: String?)] {
        switch selection {
        case "attention", "all", nil:
            projects.flatMap { p in p.repos.map { ($0, Optional(p.name)) } }
        default:
            projects.first { $0.id == selection }?.repos.map { ($0, nil) } ?? []
        }
    }

    private var visibleRepos: [(repo: RepoItem, caption: String?)] {
        entries.filter { $0.repo.needsAttention }
    }

    private var quietRepos: [(repo: RepoItem, caption: String?)] {
        selection == "attention" ? [] : entries.filter { !$0.repo.needsAttention }
    }

    private var title: String {
        switch selection {
        case "attention", nil: "Needs Attention"
        case "all": "All Repositories"
        default: projects.first { $0.id == selection }?.name ?? ""
        }
    }

    private var subtitle: String {
        "\(attentionRepos.count) of \(projects.flatMap(\.repos).count) repos need you"
    }
}

struct SidebarItemRow: View {
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
            }
        }
    }
}
#endif
