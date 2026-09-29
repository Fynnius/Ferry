# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — 2026-09-29

### Added

- **Choose which repos Ferry shows** during setup: a checklist by project with Select All / Deselect All, a filter, a count, and when you last worked in each repo. Repos untouched for 6 months or more start unchecked; unchecked repos are hidden and come back from **Settings → Folders**.
- **Connect GitHub.** When repos use GitHub over HTTPS and git can't sign in there, setup offers **Connect GitHub CLI**, which runs `gh auth setup-git` so git — in Ferry and in Terminal — signs in with the GitHub CLI. The same status and button are in **Settings → Git**. We recommend `gh auth login` + `gh auth setup-git` for HTTPS GitHub remotes; SSH keys work just as well.
- **One list, grouped by what to do next:** Needs a Fix, Changes, Ready to Push, Not Published, Updates Available, Dormant (folded) and Up to Date, each with its symbol and colour. Every row lines up in the same columns — name, branch, what it needs ("3 changes", "2 to push", "34 to pull") and one button (Push, Pull, Sync, Publish) — across the window's full width.
- **Open and fold a repo on purpose** with the chevron before its name, ←/→, or a click on a folded row. A folded repo keeps its message and shows "Draft".
- **Worktrees** are rows like any repo, named by their repo with a "worktree" tag and their branch, only while they have work; the rest are in the repo's "…" menu under Worktrees. A worktree's local-only branch isn't a to-do.
- **Settings → General → Run Setup Again…** starts setup over: folders and how you organised the repos are forgotten, preferences and your OpenAI key stay.
- **Suggest Groups…** for Other Repositories (setup, the sidebar's context menu, Settings → Folders) uses Apple Intelligence on this Mac: repo names never leave it, and nothing changes until you accept a suggestion.
- **Pull all repos with updates** from the menu bar extra and Dock menu.

### Changed

- **Needs Attention is calmer.** A repo that only needs a pull moves to **Updates Available**, and changes nobody touched for about 6 months to **Dormant**; neither counts as needing you. Every list is ordered by what to do next: problems, ready to push, then changes by most recent edit.
- **Big change lists stay usable:** a repo shows its first files and "Show All", large groups list by folder with a count (stage or unstage a whole folder), and an expanded list scrolls inside its card so the next repo is always one scroll away.
- **The menu bar extra and Dock menu** group repos by what to do next, show at most 12, and name worktrees by branch.
- **History** follows commit dates, so long-lived branches no longer fan out into dozens of lanes, and the graph never takes more than about a third of the column: commit messages always stay readable.
- The sidebar, toolbar and History share one look: no hard line under the History header, counts as badges, and a slightly wider sidebar so "Needs Attention" isn't cut off.
- Repos stop at a comfortable width on wide windows.
- Names that differ only by punctuation or a suffix (`ChartScope-Screener`, `ChartScope.Screener`, `…V2`, `… Kopie`) now group together.
- **Fetch All** never asks for a sign-in either; repos that need one join the same note.
- **Background fetch never asks for a sign-in.** Repos it can't fetch without one wait quietly, summed up in one note per host ("5 repos can't fetch from GitHub until git can sign in") with the fix, instead of a dialog per repo every few minutes.
- **Sign-in dialogs come one at a time**, and after you cancel one, others for the same server stay away for a minute. For GitHub the dialog never asks for a password: it offers the GitHub CLI or takes a token.
- An authentication error on a push, pull or fetch now offers **Sign In…**.

### Fixed

- **Stop and Continue** during the first scan now shows what was found so far.
- A file both staged and edited again no longer leaves a blank gap in the change list.

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

[Unreleased]: https://github.com/Fynnius/Ferry/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Fynnius/Ferry/compare/v0.9.0...v1.0.0
[0.9.0]: https://github.com/Fynnius/Ferry/releases/tag/v0.9.0
