import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FerryKit

/// Conflicts / Staged / Changes groups. No diff view (declined), so each row is
/// identity + state, with stage/unstage on hover, multi-select and a context menu.
///
/// Big lists stay usable: a group with many files lists them by folder, a long list
/// previews its first rows with "Show All", and the whole list then scrolls inside a
/// bounded region so the stack below it is always one scroll away. Rows are one flat,
/// lazily drawn list, so a repo with thousands of changes costs what's on screen.
struct ChangeList: View {
    var repo: RepoItem
    var status: RepoStatus
    @Namespace private var rows
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var foldedSections: Set<ChangeSection.Kind> = []
    /// Folders the user opened (true) or folded (false), over `ChangeLines.opensByDefault`.
    @State private var openFolders: [String: Bool] = [:]
    @State private var showsAll = false

    /// Above this many changes something probably belongs in .gitignore.
    static let manyChanges = 2000
    /// Lists up to this many rows draw in full; longer ones preview `previewLines`.
    static let inlineLines = 14
    static let previewLines = 10
    /// Height of the scrolling region once "Show All" is on: a row and a half short of
    /// a round number, so the cut-off row says there's more to scroll.
    static let scrollHeight = Metrics.rowHeight * 13.5

    var body: some View {
        let sections = ChangeSection.sections(of: status)
        let lines = ChangeLines.build(sections, folded: foldedSections, isOpen: isOpen)
        let scrolls = showsAll && lines.count > Self.inlineLines
        VStack(alignment: .leading, spacing: 10) {
            if status.changedPathCount > Self.manyChanges {
                Label("\(status.changedPathCount.formatted()) changes — if a dependency or build folder is showing up here, add it to .gitignore.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                if scrolls {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in view(for: line, sections: sections, animates: false) }
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, -4)
                    .frame(height: min(Self.scrollHeight, lines.reduce(0) { $0 + $1.height }))
                } else {
                    // Few rows: drawn as they are, and a staged file slides between groups.
                    let shown = lines.count > Self.inlineLines ? ChangeLines.preview(lines, rows: Self.previewLines) : lines
                    let movable = ChangeLines.pathsInOneGroup(sections)
                    ForEach(shown) { line in view(for: line, sections: sections, animates: movable.contains(line.path ?? "")) }
                }
                if lines.count > Self.inlineLines {
                    showAllButton(lines: lines, sections: sections)
                }
            }
        }
    }

    @ViewBuilder
    private func view(for line: ChangeLines.Line, sections: [ChangeSection], animates: Bool) -> some View {
        switch line.kind {
        case .header(let section):
            SectionHeader(repo: repo, section: section, isFolded: foldedSections.contains(section.kind)) {
                Motion.animate {
                    if foldedSections.contains(section.kind) { foldedSections.remove(section.kind) } else { foldedSections.insert(section.kind) }
                }
            }
            .padding(.top, line.isFirst ? 0 : 10)
        case .folder(let section, let folder, let files):
            FolderRow(repo: repo, folder: folder, files: files, action: section.action, isOpen: isOpen(section, folder, count: files.count)) {
                toggle(section, folder, count: files.count)
            }
        case .file(let section, let file, let folder):
            FileRow(
                repo: repo,
                file: file,
                action: section.action,
                isSelected: selection.contains(file.id),
                directory: folder.map { ChangeLines.relativeDirectory(of: file, in: $0) },
                onClick: { modifiers in click(file, in: section, modifiers: modifiers) },
                selectedFiles: { selectedFiles(including: file, in: section) }
            )
            .padding(.leading, folder == nil ? 0 : 22)
            .modifier(FileMove(id: animates ? file.path : nil, namespace: rows))
        case .more(let count):
            Text("and \(count.formatted()) more files")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.leading, 22)
                .frame(height: Metrics.rowHeight)
                .help("Only the first \(ChangeLines.rowLimit) are listed. Stage All and Commit All still include every file.")
        }
    }

    private func showAllButton(lines: [ChangeLines.Line], sections: [ChangeSection]) -> some View {
        let files = sections.reduce(0) { $0 + $1.files.count }
        let hasFolders = lines.contains { if case .folder = $0.kind { true } else { false } }
        let title = showsAll ? "Show Less" : hasFolders ? "Show All" : "Show All \(files.formatted()) Files"
        return Button(title) {
            Motion.animate { showsAll.toggle() }
        }
        .buttonStyle(.link)
        .font(.callout)
        .padding(.leading, 22)
        .frame(height: Metrics.rowHeight)
        .help(showsAll ? "List only the first files" : "List every file here; the list scrolls on its own")
    }

    private func isOpen(_ section: ChangeSection, _ folder: String, count: Int) -> Bool {
        openFolders[ChangeLines.folderID(section, folder)] ?? ChangeLines.opensByDefault(count)
    }

    /// Opening a folder also lets the list scroll, so its files aren't cut off by the preview.
    private func toggle(_ section: ChangeSection, _ folder: String, count: Int) {
        let open = !isOpen(section, folder, count: count)
        Motion.animate {
            openFolders[ChangeLines.folderID(section, folder)] = open
            if open { showsAll = true }
        }
    }

    /// Click selects; ⌘ toggles; ⇧ extends from the last clicked row in the same group.
    private func click(_ file: FileChange, in section: ChangeSection, modifiers: NSEvent.ModifierFlags) {
        let files = section.files
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
    private func selectedFiles(including file: FileChange, in section: ChangeSection) -> [FileChange] {
        guard selection.contains(file.id) else { return [file] }
        return section.files.filter { selection.contains($0.id) }
    }
}

/// `fileMove`: a row slides between Staged and Changes. Only for short lists and paths
/// that sit in one group — a file staged and then edited again is in both, and two rows
/// claiming one id made SwiftUI draw one on top of the other and leave a hole.
private struct FileMove: ViewModifier {
    var id: String?
    var namespace: Namespace.ID

    func body(content: Content) -> some View {
        if let id {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// One group of the change list: which files, and what its rows' button does.
struct ChangeSection: Hashable {
    enum Kind: Hashable { case conflicts, staged, changes }
    var kind: Kind
    var title: String
    var files: [FileChange]
    var action: StageAction

    static func sections(of status: RepoStatus) -> [ChangeSection] {
        var sections: [ChangeSection] = []
        if !status.conflicted.isEmpty {
            sections.append(ChangeSection(kind: .conflicts, title: "Conflicts", files: status.conflicted, action: .markResolved))
        }
        if !status.staged.isEmpty {
            sections.append(ChangeSection(kind: .staged, title: "Staged", files: status.staged, action: .unstage))
        }
        let changes = status.unstaged + status.untracked
        if !changes.isEmpty {
            sections.append(ChangeSection(kind: .changes, title: status.staged.isEmpty ? "Changes" : "Not Staged", files: changes, action: .stage))
        }
        return sections
    }
}

/// The change list flattened into the rows it draws, so a long list can be drawn lazily
/// and cut anywhere. Pure, so it's tested without a view.
enum ChangeLines {
    struct Line: Identifiable {
        enum Kind {
            case header(ChangeSection)
            /// A folder (path relative to the repo, no trailing slash) and every file in it.
            case folder(ChangeSection, String, [FileChange])
            /// A file, and the folder row it's listed under, if any.
            case file(ChangeSection, FileChange, folder: String?)
            case more(Int)
        }
        var id: String
        var kind: Kind
        var isFirst = false

        var path: String? {
            if case .file(_, let file, _) = kind { file.path } else { nil }
        }

        /// Drawn height, for sizing the scrolling region without measuring.
        var height: CGFloat {
            if case .header = kind { isFirst ? 24 : 34 } else { Metrics.rowHeight }
        }
    }

    /// Groups with more files than this list them by folder.
    static let folderAbove = 30
    /// Files listed per folder (or per group); the rest are counted.
    static let rowLimit = 300

    /// Small folders start open, big ones folded ("storefront-landing/ 1,402").
    static func opensByDefault(_ fileCount: Int) -> Bool { fileCount <= 20 }

    static func folderID(_ section: ChangeSection, _ folder: String) -> String {
        "\(section.kind):\(folder)"
    }

    static func build(_ sections: [ChangeSection], folded: Set<ChangeSection.Kind>, isOpen: (ChangeSection, String, Int) -> Bool) -> [Line] {
        var lines: [Line] = []
        for section in sections {
            lines.append(Line(id: "header:\(section.kind)", kind: .header(section), isFirst: lines.isEmpty))
            guard !folded.contains(section.kind) else { continue }
            guard section.files.count > folderAbove else {
                lines += files(section.files.prefix(rowLimit), of: section, folder: nil)
                continue
            }
            let (folders, loose) = folders(of: section.files)
            for (folder, files) in folders {
                lines.append(Line(id: "folder:\(folderID(section, folder))", kind: .folder(section, folder, files)))
                if isOpen(section, folder, files.count) {
                    lines += self.files(files.prefix(rowLimit), of: section, folder: folder)
                    if files.count > rowLimit {
                        lines.append(Line(id: "more:\(folderID(section, folder))", kind: .more(files.count - rowLimit)))
                    }
                }
            }
            lines += files(loose.prefix(rowLimit), of: section, folder: nil)
        }
        return lines
    }

    /// The first rows of a long list: every group keeps its header and a fair share of
    /// its rows, so a big group can't hide a small one below it.
    static func preview(_ lines: [Line], rows: Int) -> [Line] {
        let sections = lines.count { if case .header = $0.kind { true } else { false } }
        let share = max(3, rows / max(sections, 1))
        var shown: [Line] = []
        var taken = 0
        for line in lines {
            if case .header = line.kind {
                taken = 0
                shown.append(line)
            } else if taken < share {
                taken += 1
                shown.append(line)
            }
        }
        return shown
    }

    private static func files(_ files: ArraySlice<FileChange>, of section: ChangeSection, folder: String?) -> [Line] {
        files.map { Line(id: "file:\($0.id)", kind: .file(section, $0, folder: folder)) }
    }

    /// Splits files by the first folder below the directory they all share, so a list
    /// that all lives in `src/` groups by what's inside `src/`. Folders holding a single
    /// file don't earn a row; that file is listed loose. Folders come first, by name.
    static func folders(of files: [FileChange]) -> (folders: [(String, [FileChange])], loose: [FileChange]) {
        let directories = files.map { $0.directory.split(separator: "/") }
        var common = directories.first ?? []
        for directory in directories.dropFirst() {
            common = Array(zip(common, directory).prefix { $0 == $1 }.map(\.0))
            if common.isEmpty { break }
        }
        var byFolder: [String: [FileChange]] = [:]
        var loose: [FileChange] = []
        for (file, directory) in zip(files, directories) {
            guard directory.count > common.count else {
                loose.append(file)
                continue
            }
            byFolder[directory.prefix(common.count + 1).joined(separator: "/"), default: []].append(file)
        }
        var folders: [(String, [FileChange])] = []
        for (folder, files) in byFolder {
            if files.count > 1 { folders.append((folder, files)) } else { loose += files }
        }
        folders.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        loose.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (folders, loose)
    }

    /// A file's directory below its folder row, e.g. "src/pages" under "landing".
    static func relativeDirectory(of file: FileChange, in folder: String) -> String {
        file.directory == folder ? "" : String(file.directory.dropFirst(folder.count + 1))
    }

    /// Paths listed in exactly one group, the only ones that can animate between groups.
    static func pathsInOneGroup(_ sections: [ChangeSection]) -> Set<String> {
        var counts: [String: Int] = [:]
        for section in sections { for file in section.files { counts[file.path, default: 0] += 1 } }
        return Set(counts.filter { $0.value == 1 }.keys)
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

    var folderTitle: String {
        self == .markResolved ? "Mark Folder Resolved" : "\(title) Folder"
    }

    func run(on files: [FileChange], in repo: RepoItem) {
        Task {
            switch self {
            case .stage: await repo.stage(files)
            case .unstage: await repo.unstage(files)
            case .markResolved: await repo.markResolved(files)
            }
        }
    }
}

/// "Staged 12": folds its group; Stage/Unstage All on hover (and for VoiceOver).
private struct SectionHeader: View {
    var repo: RepoItem
    var section: ChangeSection
    var isFolded: Bool
    var onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let count = section.files.count
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(count)")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.title), \(count == 1 ? "1 file" : "\(count) files"), \(isFolded ? "collapsed" : "expanded")")
            .accessibilityActions {
                // The hover-only "… All" button is invisible to VoiceOver.
                Button(section.action.allTitle) { runAll() }
            }
            Button(action: runAll) {
                Image(systemName: section.action.symbol)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(section.action.allTitle)
            .accessibilityLabel(section.action.allTitle)
            .opacity(hovering ? 1 : 0)
            .disabled(repo.activity != nil)
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func runAll() {
        switch section.action {
        case .stage: Task { await repo.stageAll() }
        case .unstage: Task { await repo.unstageAll() }
        case .markResolved: section.action.run(on: section.files, in: repo)
        }
    }
}

/// "storefront-landing/  1,402": opens or folds its files; stage/unstage the folder.
private struct FolderRow: View {
    var repo: RepoItem
    var folder: String
    var files: [FileChange]
    var action: StageAction
    var isOpen: Bool
    var onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                    Image(nsImage: FileIcons.folder)
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(folder + "/")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(files.count.formatted())
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(folder), folder, \(files.count == 1 ? "1 file" : "\(files.count) files"), \(isOpen ? "expanded" : "collapsed")")
            .accessibilityActions {
                Button(action.folderTitle) { action.run(on: files, in: repo) }
            }
            Button { action.run(on: files, in: repo) } label: {
                Image(systemName: action.symbol)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(action.folderTitle)
            .accessibilityLabel(action.folderTitle)
            .opacity(hovering ? 1 : 0)
            .disabled(repo.activity != nil)
            // Lines up with the status letters of the file rows.
            Color.clear.frame(width: 14, height: 1)
        }
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
                .padding(.horizontal, -4)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("\(action.folderTitle) (\(files.count.formatted()) Files)") { action.run(on: files, in: repo) }
            Divider()
            Button("Reveal in Finder") { Opener.reveal(repo.path.appendingPathComponent(folder)) }
            Button("Copy Path") { Opener.copy(repo.path.appendingPathComponent(folder).path) }
            Button("Copy Relative Path") { Opener.copy(folder) }
        }
    }
}

struct FileRow: View {
    var repo: RepoItem
    var file: FileChange
    var action: StageAction?
    var isSelected: Bool
    /// The directory to show, when a folder row above already says part of it.
    var directory: String? = nil
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
            Text(directory ?? file.directory)
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
        action.run(on: files, in: repo)
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
