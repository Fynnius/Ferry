import SwiftUI
import FerryKit

// Owned by the engine/discovery side (not the design pass): hooks the repo card calls so
// fleet features (worktree/duplicate labels, move/hide/pin) can land without editing
// the card's design files.

/// Small caption next to the repo name, e.g. "Worktree of harbor-web" or "2 copies on
/// this Mac" (a menu that picks which copy Ferry shows).
struct RepoNoteView: View {
    var repo: RepoItem
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        if repo.copies.count > 1 {
            Menu {
                Section("Ferry shows this copy") {
                    ForEach(repo.copies, id: \.self) { copy in
                        Button {
                            app?.usePrimaryCopy(copy, for: repo)
                        } label: {
                            if copy == repo.path {
                                Label(Self.shortPath(copy), systemImage: "checkmark")
                            } else {
                                Text(Self.shortPath(copy))
                            }
                        }
                    }
                }
            } label: {
                // Just the glyph: the sentence is in the tooltip and the menu.
                Image(systemName: "square.on.square")
                    .imageScale(.small)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .help("\(repo.note ?? "\(repo.copies.count) copies on this Mac"). Choose which copy Ferry shows.")
            .accessibilityLabel("\(repo.copies.count) copies on this Mac. Choose which copy Ferry shows")
        } else if let note = repo.note, repo.worktreeOf == nil {
            // Worktrees say it with their "worktree" tag; snoozes in the state column.
            Text(note)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    static func shortPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// "Worktrees" in a repo's "…" menu: its linked worktrees by branch, with where each one
/// lives (the folder name only here — tool-made folders like `wt_3f2a9c1b-89e-1` say
/// nothing). Worktrees with work are rows of their own; "Show" goes there.
struct WorktreesSubmenu: View {
    var repo: RepoItem
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        if let worktrees = app?.worktrees(of: repo), !worktrees.isEmpty {
            Menu("Worktrees (\(worktrees.count))", systemImage: "rectangle.stack") {
                ForEach(worktrees.sorted { branch($0).localizedStandardCompare(branch($1)) == .orderedAscending }) { worktree in
                    Menu {
                        Text(RepoNoteView.shortPath(worktree.path))
                        if worktree.isActive || worktree.hasSomethingPending || worktree.urgency != .clear {
                            Button("Show") { app?.focus(worktree) }
                        }
                        Divider()
                        Button("Open in Terminal", systemImage: "terminal") {
                            Opener.openInTerminal(worktree.path, bundleID: app?.settings.terminalBundleID ?? "")
                        }
                        Button("Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right") {
                            Opener.openInEditor(worktree.path, bundleID: app?.settings.editorBundleID ?? "")
                        }
                        Button("Reveal in Finder", systemImage: "folder") { Opener.reveal(worktree.path) }
                        Button("Copy Path", systemImage: "doc.on.doc") { Opener.copy(worktree.path.path) }
                    } label: {
                        let state = worktree.stateSummary
                        Text(state.isEmpty ? branch(worktree) : "\(branch(worktree))  —  \(state)")
                    }
                }
            }
        }
    }

    private func branch(_ worktree: RepoItem) -> String {
        worktree.status?.branch.head ?? worktree.name
    }
}

/// Organise items for the repo's "…" and context menus (Move to Project, Hide, Pin…).
struct RepoOrganizeMenuItems: View {
    var repo: RepoItem
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        if let app {
            Divider()
            if repo.isSnoozed {
                Button("Unsnooze", systemImage: "bell") { app.unsnooze(repo) }
            } else if repo.status?.needsAttention == true {
                Button("Snooze Until It Changes", systemImage: "bell.slash") { app.snooze(repo) }
                    .help("Hide from Needs Attention until something in this repo changes. Your changes stay as they are.")
            }
        }
        if let app, repo.entryID != nil {
            Divider()
            Menu("Move to Project") {
                ForEach(app.moveTargets.filter { target in !(app.projects.first { $0.projectID == target.id }?.repos.contains { $0.id == repo.id } ?? false) }, id: \.id) { target in
                    Button(target.name) { app.move(repo, to: target.id) }
                }
                Divider()
                Button("New Project…") { app.newProjectRequest = repo }
            }
            Button(repo.isPinned ? "Unpin" : "Pin to Top", systemImage: repo.isPinned ? "pin.slash" : "pin") {
                app.setPinned(repo, !repo.isPinned)
            }
            Button("Hide Repository", systemImage: "eye.slash") { app.setHidden(repo, true) }
        }
    }
}
