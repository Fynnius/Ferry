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
    @State private var columnWidth: CGFloat = 340

    private static let pageSize = 150

    /// Lanes the graph column may use: about 30 % of the column, never fewer than 4. The
    /// rest always belongs to the commit subjects.
    private var laneCap: Int {
        max(4, Int(columnWidth * 0.3 / CommitRow.laneWidth))
    }

    var body: some View {
        let repo = app.commandTarget
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // As wide as the loaded history needs, up to the cap; one width for
                // every row so subjects line up and don't shift while scrolling.
                let lanes = min(rows.map(\.width).max() ?? 1, laneCap)
                ForEach(rows, id: \.commit.id) { row in
                    CommitRow(row: row, lanes: lanes)
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
        // The header is a bar over the list rather than a block above a divider: commits
        // scroll under it with the same soft edge as the stack.
        .safeAreaBar(edge: .top) {
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
                if let error {
                    Text(error).foregroundStyle(.secondary).padding([.horizontal, .bottom], 12)
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay {
            if rows.isEmpty && !loading && error == nil {
                ContentUnavailableView("No commits yet", systemImage: "clock")
            }
        }
        // The graph is content, like the stack (RES-1: glass only on navigation chrome), so
        // it sits on the stack's background: two surfaces in the window, not three.
        .background(.background)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
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
    /// Lanes the graph column shows; lanes past it fold into its right edge.
    var lanes: Int
    @State private var hovering = false

    static let height: CGFloat = 28
    static let laneWidth: CGFloat = 12

    var body: some View {
        HStack(spacing: 6) {
            // Full row height, so each row's lanes meet the next row's.
            GraphCell(row: row, lanes: lanes)
                .frame(width: CGFloat(lanes) * Self.laneWidth + 8)
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

/// Draws one row's lane segments and the commit dot. When the row has more lanes than the
/// column shows, the last visible lane becomes a fold: lanes past it run down the edge as
/// one dashed grey line, branches into and out of them curve to the edge in their own
/// colour, and a commit in a folded lane sits on the edge.
struct GraphCell: View {
    var row: GraphRow
    var lanes: Int

    static let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .brown]

    var body: some View {
        Canvas { context, size in
            let lane = CommitRow.laneWidth
            let edge = lanes - 1
            let folds = row.width > lanes
            func isFolded(_ n: Int) -> Bool { folds && n >= edge }
            func x(_ n: Int) -> CGFloat { 8 + CGFloat(min(n, edge)) * lane }
            let mid = size.height / 2
            func point(_ anchor: GraphRow.Anchor) -> CGPoint {
                switch anchor {
                case .top(let n): CGPoint(x: x(n), y: 0)
                case .bottom(let n): CGPoint(x: x(n), y: size.height)
                case .node: CGPoint(x: x(row.lane), y: mid)
                }
            }
            var drewFold = false
            for segment in row.segments {
                let from = point(segment.from)
                let to = point(segment.to)
                var path = Path()
                path.move(to: from)
                if isFolded(segment.from.lane ?? row.lane) && isFolded(segment.to.lane ?? row.lane) {
                    // Inside the fold: one dashed line for all of them.
                    guard !drewFold else { continue }
                    drewFold = true
                    path = Path()
                    path.move(to: CGPoint(x: x(edge), y: 0))
                    path.addLine(to: CGPoint(x: x(edge), y: size.height))
                    context.stroke(path, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.6, dash: [2, 3]))
                    continue
                }
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
