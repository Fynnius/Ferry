# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0] — 2026-09-29

The first public build. A pre-release: everything below works and is tested, but it hasn't had a long run on many people's Macs yet.

### Added

- **One list of the repos that need you.** Repos with changes, commits to push or pull, an unpublished branch or a merge in progress sit at the top of *Needs Attention*; clean repos fold into one quiet line each. *All Repositories* and your projects are in the sidebar, and the window narrows to a single column like an editor's sidebar.
- **Finds your repos.** Choose the folders you keep code in; Ferry scans them (up to 6 levels, skipping dependency and build folders, never downloading iCloud placeholders) and groups related repos into projects from your `.code-workspace` files, shared GitHub owners and folders. Duplicate clones show as copies of one repo, worktrees attach to their parent. Rename, move, pin or hide anything — your changes survive rescans.
- **Commit, push, sync.** Type a message and ⌘↩. With nothing staged the button reads *Commit All*; with something staged, *Commit*. After committing it turns into *Sync* or *Publish Branch*. Commit & Push, Commit & Sync, Amend and Undo Last Commit (only while unpushed) are in its menu.
- **Stage and unstage** files, groups or everything; multi-select with ⌘ and ⇧; conflicts are shown with *Mark Resolved* and an escape hatch to your editor or Terminal.
- **Branches** (⌘B): search, switch, create, rename, delete, publish. **Stashes**: stash with a message, pop, apply, drop. **History** (⌥⌘H): the repo's commit graph.
- **Stash and retry.** When a switch, pull or sync is refused because of local changes, one click stashes them and tries again. Nothing is ever discarded.
- **AI commit messages (optional).** With your own OpenAI API key, ✨ streams a message written from what you're about to commit. Files that look like secrets are never read or sent, and Ferry explains what OpenAI keeps before the first request.
- **Stays current.** File changes appear in well under a second; remotes are fetched in the background every 3 minutes (configurable, paused offline and in Low Power Mode). Tooltips say when a repo was last fetched.
- **Snooze Until It Changes** hides a repo from *Needs Attention* until its files change again.
- **Keyboard first.** ⌘] / ⌘[ jump to the next or previous repo that needs you; every action is in the menu bar with a shortcut.
- **Mac niceties.** Dock badge with the attention count, a Dock menu, an optional menu bar extra, open at login, a ⌃⌥⌘F hotkey, folders dropped onto the window or Dock icon, and *Finder ▸ Services ▸ Open in Ferry*.
- **Plain-language errors.** Rejected pushes offer Sync, failed hooks show their output, missing identity or pull settings link to the fix.
- A warning (never a block) before committing or pushing to `main`/`master`, editable in Settings.

[Unreleased]: https://github.com/Fynnius/Ferry/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/Fynnius/Ferry/releases/tag/v0.9.0
