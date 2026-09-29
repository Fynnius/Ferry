import SwiftUI
import FerryKit

// Visual language. Colour carries meaning only (file state, sync state);
// everything else stays in system neutrals so the content layer reads calm.

extension FileChange.Kind {
    /// Single-letter badge, matching what git and VS Code users already know.
    var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }

    var tint: Color {
        switch self {
        case .modified, .typeChanged: .orange
        case .added, .untracked, .copied: .green
        case .deleted, .conflicted: .red
        case .renamed: .blue
        }
    }

    var label: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .untracked: "New file"
        case .conflicted: "Conflict"
        }
    }
}

extension SyncState {
    /// The same hues as `RepoUrgency.tint`: blue to push, indigo to pull, purple not on the
    /// remote; orange where the next sync needs a decision. Always next to a count or label.
    var tint: Color {
        switch self {
        case .ahead: .blue
        case .behind: .indigo
        case .unpublished, .upstreamGone: .purple
        case .diverged: .orange
        case .noRemote, .upToDate: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .noRemote: "externaldrive"
        case .unpublished: "icloud.slash"
        case .upstreamGone: "exclamationmark.icloud"
        case .upToDate: "checkmark.icloud"
        case .ahead: "arrow.up"
        case .behind: "arrow.down"
        case .diverged: "arrow.up.arrow.down"
        }
    }

    /// Plain-language description for tooltips and VoiceOver.
    var description: String {
        switch self {
        case .noRemote: "No remote — this repo only exists on your Mac"
        case .unpublished: "Branch not published yet"
        case .upstreamGone: "The remote branch was deleted"
        case .upToDate: "Up to date with the remote"
        case .ahead(let n): "\(n) commit\(n == 1 ? "" : "s") to push"
        case .behind(let n): "\(n) commit\(n == 1 ? "" : "s") to pull"
        case .diverged(let a, let b): "\(a) to push, \(b) to pull"
        }
    }
}

enum Metrics {
    static let cardCorner: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let rowHeight: CGFloat = 26
    static let stackSpacing: CGFloat = 10
    /// Inner horizontal padding of a repo row inside its group's list.
    static let rowPadding: CGFloat = 14
    /// Outer margin of the stack; it uses the window's full width.
    static let stackMargin: CGFloat = 20
}
