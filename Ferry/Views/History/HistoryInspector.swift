import SwiftUI
import FerryKit

/// The current repo's history as a graph, in the inspector column.
struct HistoryInspector: View {
    @Environment(AppModel.self) private var app
    @State private var rows: [GraphRow] = []
    @State private var loadedRepoID: String?
    @State private var allBranches = false
    @State private var loading = false
    @State private var canLoadMore = true
    @State private var error: String?

    private static let pageSize = 150

    var body: some View {
        let repo = app.commandTarget
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("History").font(.headline)
                    Text(repo?.name ?? "No repository").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("All Branches", isOn: $allBranches)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Show every branch, not just the current one and its upstream")
            }
            .padding(12)
            Divider()
            if let error {
                Text(error).foregroundStyle(.secondary).padding(12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let width = CGFloat(rows.map(\.width).max() ?? 1)
                    ForEach(rows, id: \.commit.id) { row in
                        CommitRow(row: row, graphWidth: width)
                    }
                    if canLoadMore && !rows.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .onAppear { Task { await load(repo: repo, reset: false) } }
                    }
                }
            }
            .overlay {
                if rows.isEmpty && !loading && error == nil {
                    ContentUnavailableView("No commits yet", systemImage: "clock")
                }
            }
        }
        .task(id: TaskKey(repoID: repo?.id, allBranches: allBranches, head: repo?.status?.branch.oid)) {
            await load(repo: repo, reset: true)
        }
    }

    private struct TaskKey: Hashable {
        var repoID: String?
        var allBranches: Bool
        var head: String?
    }

    private func load(repo: RepoItem?, reset: Bool) async {
        // A reset (new repo, branch or toggle) always runs; only paging waits its turn.
        guard let git = repo?.git, reset || !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let skip = reset ? 0 : rows.count
            var commits = try await git.log(limit: Self.pageSize, skip: skip, allBranches: allBranches)
            // The repo changed while git ran: drop these rows, the newer load owns the list.
            guard !Task.isCancelled, repo?.id == app.commandTarget?.id else { return }
            if !reset { commits = rows.map(\.commit) + commits }
            canLoadMore = commits.count - (reset ? 0 : rows.count) == Self.pageSize
            rows = GraphLayout.rows(for: commits)
            loadedRepoID = repo?.id
            error = nil
        } catch {
            self.error = (error as? GitError)?.summary ?? error.localizedDescription
        }
    }
}

struct CommitRow: View {
    var row: GraphRow
    var graphWidth: CGFloat
    @State private var hovering = false

    static let height: CGFloat = 28
    static let laneWidth: CGFloat = 12

    var body: some View {
        HStack(spacing: 6) {
            // Full row height, so each row's lanes meet the next row's.
            GraphCell(row: row)
                .frame(width: graphWidth * Self.laneWidth + 8)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    ForEach(displayRefs, id: \.self) { ref in
                        RefChip(name: ref)
                    }
                    Text(row.commit.subject)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text("\(row.commit.author) · \(row.commit.date.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: Self.height + 8)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .onHover { hovering = $0 }
        .help("\(row.commit.shortID) — \(row.commit.subject)")
        .contextMenu {
            Button("Copy Commit ID") { Opener.copy(row.commit.id) }
            Button("Copy Message") { Opener.copy(row.commit.subject) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.commit.subject), by \(row.commit.author), \(row.commit.date.formatted(.relative(presentation: .named)))\(displayRefs.isEmpty ? "" : ", " + displayRefs.joined(separator: ", "))")
    }

    /// `HEAD -> main` reads as `main`; tags keep a tag glyph via RefChip.
    private var displayRefs: [String] {
        row.commit.refs.map { $0.replacingOccurrences(of: "HEAD -> ", with: "") }.filter { $0 != "HEAD" && !$0.hasSuffix("/HEAD") }
    }
}

struct RefChip: View {
    var name: String

    var body: some View {
        let isTag = name.hasPrefix("tag: ")
        let isRemote = name.contains("/") && !isTag && name.split(separator: "/").count > 1 && ["origin", "upstream"].contains(String(name.split(separator: "/")[0]))
        Label(isTag ? String(name.dropFirst(5)) : name, systemImage: isTag ? "tag" : (isRemote ? "cloud" : "arrow.triangle.branch"))
            .labelStyle(.compactIcon)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.tint.opacity(isRemote ? 0.08 : 0.15), in: Capsule())
            .foregroundStyle(.tint)
    }
}

/// Draws one row's lane segments and the commit dot.
struct GraphCell: View {
    var row: GraphRow

    static let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .brown]

    var body: some View {
        Canvas { context, size in
            let lane = CommitRow.laneWidth
            func x(_ n: Int) -> CGFloat { 8 + CGFloat(n) * lane }
            let mid = size.height / 2
            func point(_ anchor: GraphRow.Anchor) -> CGPoint {
                switch anchor {
                case .top(let n): CGPoint(x: x(n), y: 0)
                case .bottom(let n): CGPoint(x: x(n), y: size.height)
                case .node: CGPoint(x: x(row.lane), y: mid)
                }
            }
            for segment in row.segments {
                let from = point(segment.from)
                let to = point(segment.to)
                var path = Path()
                path.move(to: from)
                if from.x == to.x {
                    path.addLine(to: to)
                } else {
                    path.addCurve(to: to, control1: CGPoint(x: from.x, y: (from.y + to.y) / 2), control2: CGPoint(x: to.x, y: (from.y + to.y) / 2))
                }
                context.stroke(path, with: .color(Self.palette[segment.colorLane % Self.palette.count]), lineWidth: 1.6)
            }
            let center = CGPoint(x: x(row.lane), y: mid)
            let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            let color = Self.palette[row.lane % Self.palette.count]
            if row.commit.isMerge {
                // A hollow ring: clear the lanes under it so whatever is behind the row
                // (inspector background, hover highlight) shows through.
                var hole = context
                hole.blendMode = .clear
                hole.fill(dot, with: .color(.black))
                context.stroke(dot, with: .color(color), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}
