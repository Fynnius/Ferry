import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FerryKit

/// Staged / Changes / Conflicts groups. No diff view (declined), so each row is
/// identity + state, with stage/unstage on hover, multi-select and a context menu.
struct ChangeList: View {
    var repo: RepoItem
    var status: RepoStatus
    @Namespace private var rows
    @State private var selection: Set<String> = []

    /// Above this many changes something probably belongs in .gitignore.
    static let manyChanges = 2000

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if status.changedPathCount > Self.manyChanges {
                Label("\(status.changedPathCount.formatted()) changes — if a dependency or build folder is showing up here, add it to .gitignore.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !status.conflicted.isEmpty {
                ChangeGroup(repo: repo, title: "Conflicts", files: status.conflicted, action: .markResolved, namespace: rows, selection: $selection)
            }
            if !status.staged.isEmpty {
                ChangeGroup(repo: repo, title: "Staged", files: status.staged, action: .unstage, namespace: rows, selection: $selection)
            }
            let changes = status.unstaged + status.untracked
            if !changes.isEmpty {
                ChangeGroup(repo: repo, title: status.staged.isEmpty ? "Changes" : "Not Staged", files: changes, action: .stage, namespace: rows, selection: $selection)
            }
        }
    }
}

enum StageAction {
    case stage, unstage, markResolved

    var symbol: String {
        switch self {
        case .stage: "plus"
        case .unstage: "minus"
        case .markResolved: "checkmark"
        }
    }

    var title: String {
        switch self {
        case .stage: "Stage"
        case .unstage: "Unstage"
        case .markResolved: "Mark Resolved"
        }
    }

    var allTitle: String {
        self == .markResolved ? "Mark All Resolved" : "\(title) All"
    }
}

struct ChangeGroup: View {
    var repo: RepoItem
    var title: String
    var files: [FileChange]
    var action: StageAction?
    var namespace: Namespace.ID
    @Binding var selection: Set<String>
    @State private var expanded = true
    @State private var hovering = false
    @State private var anchor: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    Motion.animate { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("\(files.count)")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(files.count)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(files.count == 1 ? "1 file" : "\(files.count) files"), \(expanded ? "expanded" : "collapsed")")
                .accessibilityActions {
                    // The hover-only "… All" button is invisible to VoiceOver.
                    if let action { Button(action.allTitle) { runAll(action) } }
                }
                if let action {
                    Button { runAll(action) } label: {
                        Image(systemName: action.symbol)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(action.allTitle)
                    .accessibilityLabel(action.allTitle)
                    .opacity(hovering ? 1 : 0)
                    .disabled(repo.activity != nil)
                }
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }

            if expanded {
                ForEach(files.prefix(Self.rowLimit)) { file in
                    FileRow(
                        repo: repo,
                        file: file,
                        action: action,
                        isSelected: selection.contains(file.id),
                        onClick: { modifiers in click(file, modifiers: modifiers) },
                        selectedFiles: { selectedFiles(including: file) }
                    )
                    .matchedGeometryEffect(id: file.path, in: namespace)
                }
                if files.count > Self.rowLimit {
                    Text("and \(files.count - Self.rowLimit) more files")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 14)
                        .frame(height: Metrics.rowHeight)
                        .help("Only the first \(Self.rowLimit) are listed. Stage All and Commit All still include every file.")
                }
            }
        }
    }

    /// Rows drawn per group. A repo with thousands of unignored files stays responsive;
    /// group actions still cover every file.
    static let rowLimit = 300

    private func runAll(_ action: StageAction) {
        Task {
            switch action {
            case .stage: await repo.stageAll()
            case .unstage: await repo.unstageAll()
            case .markResolved: await repo.markResolved(files)
            }
        }
    }

    /// Click selects; ⌘ toggles; ⇧ extends from the last clicked row.
    private func click(_ file: FileChange, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(file.id) { selection.remove(file.id) } else { selection.insert(file.id) }
            anchor = file.id
        } else if modifiers.contains(.shift), let anchor, let from = files.firstIndex(where: { $0.id == anchor }), let to = files.firstIndex(where: { $0.id == file.id }) {
            selection = Set(files[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = selection == [file.id] ? [] : [file.id]
            anchor = file.id
        }
    }

    /// The row's action applies to the whole selection when the row is part of it.
    private func selectedFiles(including file: FileChange) -> [FileChange] {
        guard selection.contains(file.id) else { return [file] }
        return files.filter { selection.contains($0.id) }
    }
}

struct FileRow: View {
    var repo: RepoItem
    var file: FileChange
    var action: StageAction?
    var isSelected: Bool
    var onClick: (NSEvent.ModifierFlags) -> Void
    var selectedFiles: () -> [FileChange]
    @State private var hovering = false
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: file.isSubmodule ? FileIcons.folder : FileIcons.icon(for: file.fileName))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(file.fileName)
                .lineLimit(1)
                .strikethrough(file.kind == .deleted, color: .secondary)
                .layoutPriority(1)
            if let original = file.originalPath {
                Text("← \((original as NSString).lastPathComponent)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(file.directory)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let action {
                Button { run(action, on: selectedFiles()) } label: {
                    Image(systemName: action.symbol)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(action.title)
                .accessibilityLabel(action.title)
                .opacity(hovering ? 1 : 0)
                .disabled(repo.activity != nil)
            }
            Text(file.kind.letter)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(file.kind.tint)
                .frame(width: 14)
                .help(file.kind.label)
        }
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(rowFill)
                .padding(.horizontal, -4)
        }
        .onHover { hovering = $0 }
        .gesture(TapGesture(count: 2).onEnded { open() })
        .simultaneousGesture(TapGesture().onEnded { onClick(NSEvent.modifierFlags) })
        .contextMenu {
            if let action {
                let targets = selectedFiles()
                Button(targets.count > 1 ? "\(action.title) \(targets.count) Files" : action.title) { run(action, on: targets) }
                Divider()
            }
            if file.kind != .deleted {
                Button("Open") { open() }
                Button("Open in Editor") {
                    Opener.openInEditor(url, bundleID: app?.settings.editorBundleID ?? "")
                }
                Button("Reveal in Finder") { Opener.reveal(url) }
                Divider()
            }
            Button("Copy Path") { Opener.copy(url.path) }
            Button("Copy Relative Path") { Opener.copy(file.path) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.fileName), \(file.kind.label)\(file.directory.isEmpty ? "" : ", in \(file.directory)")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            if let action {
                Button(action.title) { run(action, on: [file]) }
            }
            Button("Open") { open() }
        }
    }

    private var rowFill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.selection.opacity(0.35)) }
        if hovering { return AnyShapeStyle(.quaternary.opacity(0.6)) }
        return AnyShapeStyle(.clear)
    }

    private var url: URL { repo.path.appendingPathComponent(file.path) }

    private func open() {
        guard file.kind != .deleted else { return }
        // Never runs repo contents (a .command or .app shipped in a clone opens as text).
        Opener.openFile(url, editorBundleID: app?.settings.editorBundleID ?? "")
    }

    private func run(_ action: StageAction, on files: [FileChange]) {
        Task {
            switch action {
            case .stage: await repo.stage(files)
            case .unstage: await repo.unstage(files)
            case .markResolved: await repo.markResolved(files)
            }
        }
    }
}

/// Finder's icon for a file type, cached per extension.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static let folder = NSWorkspace.shared.icon(for: .folder)

    static func icon(for fileName: String) -> NSImage {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let type = UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        cache[ext] = image
        return image
    }
}
