import SwiftUI
import FerryKit

/// The repo's stashes — pop, apply, drop — plus stashing the current changes.
struct StashList: View {
    var repo: RepoItem
    @State private var stashes: [Stash] = []
    @State private var loading = true
    @State private var message = ""
    @State private var confirmDrop: Stash?
    @State private var listHeight: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if repo.status?.hasChanges == true {
                HStack {
                    TextField("Stash message (optional)", text: $message)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(stashNow)
                    Button("Stash", action: stashNow)
                }
                Divider()
            }
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if stashes.isEmpty {
                Text("No stashes.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(stashes) { stash in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Self.cleanMessage(stash.message)).lineLimit(2)
                                    Text(stash.date.formatted(.relative(presentation: .named)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Pop") { run { try await $0.popStash(stash) } }
                                    .help("Apply and remove from the list")
                                Menu {
                                    Button("Apply (keep in list)") { run { try await $0.applyStash(stash) } }
                                    Divider()
                                    Button("Drop…", role: .destructive) { confirmDrop = stash }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.button)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                            .controlSize(.small)
                            .padding(6)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // As tall as the list, up to 260 pt; then it scrolls.
                .frame(height: min(max(listHeight, 1), 260))
            }
        }
        .padding(12)
        .frame(width: 340)
        .task { await load() }
        .confirmationDialog("Drop this stash?", isPresented: .init(get: { confirmDrop != nil }, set: { if !$0 { confirmDrop = nil } })) {
            Button("Drop Stash", role: .destructive) {
                if let stash = confirmDrop { run { try await $0.dropStash(stash) } }
            }
        } message: {
            Text("Its changes are deleted and can't be recovered from Ferry.")
        }
    }

    /// `On main: WIP` → `WIP`; git's default `WIP on main: abc123 subject` stays readable.
    static func cleanMessage(_ message: String) -> String {
        if message.hasPrefix("On "), let colon = message.firstIndex(of: ":") {
            return String(message[message.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return message
    }

    private func load() async {
        guard let git = repo.git else { return }
        stashes = (try? await git.stashes()) ?? []
        loading = false
    }

    private func stashNow() {
        let text = message
        dismiss()
        Task { await repo.stash(message: text) }
    }

    private func run(_ work: @escaping (GitRepository) async throws -> Void) {
        dismiss()
        Task { await repo.perform(.stashing, work) }
    }
}
