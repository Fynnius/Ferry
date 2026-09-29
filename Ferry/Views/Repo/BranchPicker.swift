import SwiftUI
import FerryKit

/// Searchable branch popover — switch, create, rename, delete, publish.
struct BranchPicker: View {
    var repo: RepoItem
    @State private var branches: [Branch] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    @State private var renaming: Branch?
    @State private var newName = ""
    @State private var confirmForceDelete: Branch?
    @State private var listHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Find or create a branch", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(submit)

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if canCreate {
                        BranchRowButton(symbol: "plus", title: "Create “\(trimmedQuery)”", subtitle: "from \(repo.status?.branch.head ?? "HEAD")") {
                            Task { await create() }
                        }
                    }
                    let locals = filtered.filter { !$0.isRemote }
                    let remotes = filtered.filter { $0.isRemote && !localNames.contains($0.nameWithoutRemote) }
                    if !locals.isEmpty { sectionTitle("Local") }
                    ForEach(locals) { branch in row(branch) }
                    if !remotes.isEmpty { sectionTitle("Remote") }
                    ForEach(remotes) { branch in row(branch) }
                    if loading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else if filtered.isEmpty && !canCreate {
                        Text("No branches match.").foregroundStyle(.secondary).padding(8)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            // As tall as the list, up to 280 pt; then it scrolls.
            .frame(height: min(max(listHeight, 1), 280))
        }
        .padding(12)
        .frame(width: 340)
        .task { await load() }
        .onAppear { searchFocused = true }
        .alert("Rename Branch", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $newName)
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "“\(confirmForceDelete?.name ?? "")” has commits that aren't merged anywhere.",
            isPresented: .init(get: { confirmForceDelete != nil }, set: { if !$0 { confirmForceDelete = nil } })
        ) {
            Button("Delete Anyway", role: .destructive) {
                if let branch = confirmForceDelete { Task { await delete(branch, force: true) } }
            }
        } message: {
            Text("Deleting it loses those commits unless another branch or the remote has them.")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .padding(.leading, 6)
    }

    @ViewBuilder
    private func row(_ branch: Branch) -> some View {
        BranchRowButton(
            symbol: branch.isCurrent ? "checkmark" : (branch.isRemote ? "cloud" : "arrow.triangle.branch"),
            title: branch.isRemote ? branch.name : branch.name,
            subtitle: subtitle(for: branch),
            emphasized: branch.isCurrent
        ) {
            guard !branch.isCurrent else { return }
            Task { await switchTo(branch) }
        }
        .contextMenu {
            if !branch.isRemote {
                Button("Rename…") {
                    newName = branch.name
                    renaming = branch
                }
                if branch.isCurrent, branch.upstream == nil {
                    Button("Publish Branch") {
                        dismiss()
                        Task { await repo.publish() }
                    }
                }
                Button("Delete", role: .destructive) { Task { await delete(branch, force: false) } }
                    .disabled(branch.isCurrent)
            }
            Button("Copy Name") { Opener.copy(branch.isRemote ? branch.nameWithoutRemote : branch.name) }
        }
    }

    private func subtitle(for branch: Branch) -> String {
        var parts: [String] = []
        if branch.upstreamGone { parts.append("remote gone") }
        if branch.ahead > 0 { parts.append("\(branch.ahead)↑") }
        if branch.behind > 0 { parts.append("\(branch.behind)↓") }
        if let date = branch.lastCommitDate { parts.append(date.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var localNames: Set<String> { Set(branches.filter { !$0.isRemote }.map(\.name)) }

    private var filtered: [Branch] {
        guard !trimmedQuery.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    private var canCreate: Bool {
        !trimmedQuery.isEmpty && !trimmedQuery.contains(" ") && !branches.contains { $0.name == trimmedQuery || $0.nameWithoutRemote == trimmedQuery }
    }

    private func submit() {
        if let exact = filtered.first(where: { $0.name == trimmedQuery || $0.nameWithoutRemote == trimmedQuery }) ?? (filtered.count == 1 ? filtered.first : nil) {
            Task { await switchTo(exact) }
        } else if canCreate {
            Task { await create() }
        }
    }

    private func load() async {
        guard let git = repo.git else { return }
        do {
            branches = try await git.branches()
        } catch {
            self.error = (error as? GitError)?.summary ?? error.localizedDescription
        }
        loading = false
    }

    private func switchTo(_ branch: Branch) async {
        dismiss()
        await repo.switchTo(branch)
    }

    private func create() async {
        guard let git = repo.git else { return }
        let name = trimmedQuery
        guard await git.isValidBranchName(name) else {
            error = "“\(name)” isn't a valid branch name."
            return
        }
        dismiss()
        await repo.perform(.switchingBranch) { git in try await git.createBranch(name) }
    }

    private func rename() async {
        guard let branch = renaming, let git = repo.git else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard await git.isValidBranchName(name) else {
            error = "“\(name)” isn't a valid branch name."
            return
        }
        do {
            try await git.renameBranch(branch.name, to: name)
            error = nil
            await load()
            await repo.refresh()
        } catch {
            self.error = (error as? GitError)?.summary ?? error.localizedDescription
        }
    }

    private func delete(_ branch: Branch, force: Bool) async {
        guard let git = repo.git else { return }
        do {
            try await git.deleteBranch(branch.name, force: force)
            error = nil
            await load()
        } catch let gitError as GitError where gitError.kind == .branchNotFullyMerged {
            confirmForceDelete = branch
        } catch {
            self.error = (error as? GitError)?.summary ?? error.localizedDescription
        }
    }
}

struct BranchRowButton: View {
    var symbol: String
    var title: String
    var subtitle: String
    var emphasized = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(emphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .fontWeight(emphasized ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
