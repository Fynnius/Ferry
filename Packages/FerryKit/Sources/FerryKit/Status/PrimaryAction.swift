/// The one action a repo's main button offers, following VS Code's state machine:
/// changes → Commit (staged only) or Commit All (nothing staged); otherwise an
/// unpublished branch → Publish Branch; otherwise commits to exchange → Sync.
public enum PrimaryAction: Hashable, Sendable {
    /// Commit. `all` is true when nothing is staged, so every change gets committed.
    case commit(all: Bool)
    case publish
    case sync(ahead: Int, behind: Int)
    /// Nothing to do: clean and up to date, or a state the button can't resolve.
    case none

    public init(status: RepoStatus) {
        if !status.conflicted.isEmpty {
            self = .none
        } else if !status.staged.isEmpty {
            self = .commit(all: false)
        } else if status.hasChanges {
            self = .commit(all: true)
        } else {
            switch status.syncState {
            case .unpublished where status.branch.hasCommits && !status.branch.isDetached:
                self = .publish
            case .ahead(let a):
                self = .sync(ahead: a, behind: 0)
            case .behind(let b):
                self = .sync(ahead: 0, behind: b)
            case .diverged(let a, let b):
                self = .sync(ahead: a, behind: b)
            default:
                self = .none
            }
        }
    }
}
