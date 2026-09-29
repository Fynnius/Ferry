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
                Label(repo.note ?? "\(repo.copies.count) copies", systemImage: "square.on.square")
                    .labelStyle(.compactIcon)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .help("This repo is cloned more than once on your Mac. Choose which copy Ferry shows.")
        } else if repo.isSnoozed {
            Text("Snoozed")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .help("Out of Needs Attention until something in this repo changes")
        } else if let note = repo.note {
            // Plain text: the branch control next to it already carries the branch glyph.
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
