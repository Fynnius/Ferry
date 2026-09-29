import AppKit

/// "Next repo that needs you": ⌘] / ⌘[ and the move to the next repo once one is done.
extension AppModel {
    /// The repo `step` places away from the current one, in the order the stack shows the
    /// current list, that needs the user. Wraps around; the current repo itself comes last.
    func repoNeedingYou(step: Int) -> RepoItem? {
        let entries = entries(for: selection)
        let order = (entries.active + entries.quiet).map(\.repo)
        let count = order.count
        guard count > 0 else { return nil }
        let start = currentRepoID.flatMap { id in order.firstIndex { $0.id == id } } ?? (step > 0 ? -1 : count)
        for offset in 1...count {
            let index = ((start + offset * step) % count + count) % count
            if order[index].needsAttention { return order[index] }
        }
        return nil
    }

    /// ⌘] / ⌘[. Beeps when nothing in the list needs the user.
    func goToRepoNeedingYou(step: Int) {
        guard let repo = repoNeedingYou(step: step) else {
            NSSound.beep()
            return
        }
        focus(repo)
    }

    /// Makes `repo` current, scrolls to it and puts the keyboard where its work is: the
    /// message field when it has changes, else the card itself.
    func focus(_ repo: RepoItem) {
        currentRepoID = repo.id
        scrollTarget = repo.id
        guard repo.status?.hasChanges == true else {
            focusCardRequest = repo.id
            return
        }
        repo.focusMessageCount += 1
        // A collapsed card only grows its message field once it's current, and the lazy
        // stack only draws it once scrolled to; ask again a beat later for those.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard self?.currentRepoID == repo.id else { return }
            repo.focusMessageCount += 1
        }
    }

    /// Called when a commit, push, pull, sync or publish succeeds. If that left the repo with
    /// nothing to do, moves on to the next repo that needs the user, as ⌘] would — but only
    /// while the user is still on that repo and not typing somewhere else, so it never
    /// takes the keyboard away. A plain commit that leaves commits to push doesn't count:
    /// push is deploy, and ⌥⌘P/⌥⌘S must keep acting on the repo just committed in.
    func repoFinished(_ repo: RepoItem, typingAtStart: ObjectIdentifier?) {
        guard currentRepoID == repo.id, !repo.needsAttention, repo.problem == nil,
              NSApp.keyWindow?.sheetParent == nil else { return }
        let typing = Self.textFieldBeingEdited()
        guard typing == nil || typing == typingAtStart else { return }
        guard let next = repoNeedingYou(step: 1), next.id != repo.id else { return }
        focus(next)
    }

    /// The text field or text view that has the keyboard in the key window, if any. Text
    /// fields share one field editor, so its owner is what identifies the field.
    static func textFieldBeingEdited() -> ObjectIdentifier? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        if editor.isFieldEditor, let owner = editor.delegate { return ObjectIdentifier(owner) }
        return ObjectIdentifier(editor)
    }
}
