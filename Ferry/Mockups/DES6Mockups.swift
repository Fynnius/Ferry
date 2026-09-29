#if DEBUG
import SwiftUI
import FerryKit

/// Design option boards: the same sample repos drawn with competing header / composer /
/// row treatments, side by side. Launch with `-FerryMockup D6`.
struct DES6Board: View {
    @State private var projects = SampleData.projects()
    private var variant: String { UserDefaults.standard.string(forKey: "FerryMockupVariant") ?? "options" }

    var body: some View {
        let repos = projects.flatMap(\.repos)
        let web = repos.first { $0.name == "harbor-web" }!
        let api = repos.first { $0.name == "harbor-api" }!
        let atlas = repos.first { $0.name == "atlas" }!
        let ios = repos.first { $0.name == "harbor-ios" }!
        Group {
            if variant == "accordion" {
                AccordionBoard()
            } else if variant == "chosen" {
                ChosenBoard()
            } else if variant == "lab" {
                DES6ControlLab()
            } else if variant == "sizes" {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach([376.0, 760.0], id: \.self) { width in
                        HStack(alignment: .top, spacing: 18) {
                            column("inline · regular", width: width) { OptionCard(repo: api, header: .oneLine, composer: .inline, rows: .letterLeads).controlSize(.regular) }
                            column("inline · large", width: width) { OptionCard(repo: api, header: .oneLine, composer: .inline, rows: .letterLeads).controlSize(.large) }
                            if width < 400 {
                                column("under · regular", width: width) { OptionCard(repo: web, header: .oneLine, composer: .trailing, rows: .letterLeads).controlSize(.regular) }
                                column("under · large", width: width) { OptionCard(repo: web, header: .oneLine, composer: .trailing, rows: .letterLeads).controlSize(.large) }
                            }
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    column("Today") {
                        RepoSection(repo: atlas, projectCaption: "Atlas")
                        RepoSection(repo: api, projectCaption: "Harbor")
                        RepoSection(repo: ios, projectCaption: "Harbor")
                    }
                    column("A — one line, button carries state") {
                        OptionCard(repo: atlas, header: .oneLine, composer: .inline, rows: .letterLeads)
                        OptionCard(repo: api, header: .oneLine, composer: .inline, rows: .letterLeads)
                        OptionCard(repo: ios, header: .oneLine, composer: .inline, rows: .letterLeads)
                    }
                    column("B — two lines, stacked full-width button") {
                        OptionCard(repo: atlas, header: .twoLine, composer: .stacked, rows: .iconTrailing)
                        OptionCard(repo: api, header: .twoLine, composer: .stacked, rows: .iconTrailing)
                        OptionCard(repo: ios, header: .twoLine, composer: .stacked, rows: .iconTrailing)
                    }
                    column("C — branch control, button under field") {
                        OptionCard(repo: atlas, header: .branchControl, composer: .trailing, rows: .letterTrailing)
                        OptionCard(repo: api, header: .branchControl, composer: .trailing, rows: .letterTrailing)
                        OptionCard(repo: ios, header: .branchControl, composer: .trailing, rows: .letterTrailing)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .onAppear { _ = web }
    }

    private func column(_ title: String, width: CGFloat = 430, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
        .frame(width: width, alignment: .topLeading)
    }
}

enum HeaderOption { case oneLine, twoLine, branchControl }
enum ComposerOption { case inline, stacked, trailing }
enum RowOption { case letterLeads, iconTrailing, letterTrailing }

/// One repo card drawn with a given combination of options.
struct OptionCard: View {
    var repo: RepoItem
    var header: HeaderOption
    var composer: ComposerOption
    var rows: RowOption

    var body: some View {
        let hasChanges = repo.status?.hasChanges ?? false
        VStack(alignment: .leading, spacing: 0) {
            headerView
            if hasChanges, let status = repo.status {
                composerView
                    .padding(.top, 12)
                VStack(alignment: .leading, spacing: 10) {
                    if !status.staged.isEmpty { group("Staged", status.staged, action: "minus") }
                    let changes = status.unstaged + status.untracked
                    if !changes.isEmpty { group(status.staged.isEmpty ? "Changes" : "Not Staged", changes, action: "plus") }
                }
                .padding(.top, 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, hasChanges ? 14 : 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Header

    @ViewBuilder
    private var headerView: some View {
        let status = repo.status!
        let protected = repo.isProtectedBranch && (status.hasChanges || status.branch.ahead > 0)
        switch header {
        case .oneLine:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(repo.name).font(.headline).layoutPriority(2)
                Text(status.branch.head ?? "detached")
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if status.hasChanges, status.syncState != .upToDate {
                    SyncChip(state: status.syncState).labelStyle(.compactIcon)
                }
                Spacer(minLength: 8)
                if !status.hasChanges { quietButton(protected: protected) }
                moreButton
            }
        case .twoLine:
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(repo.name).font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch").imageScale(.small)
                        Text(status.branch.head ?? "detached")
                        if status.hasChanges, status.syncState != .upToDate {
                            SyncChip(state: status.syncState).labelStyle(.compactIcon)
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !status.hasChanges { quietButton(protected: protected) }
                moreButton
            }
        case .branchControl:
            HStack(alignment: .center, spacing: 6) {
                Text(repo.name).font(.headline).layoutPriority(2)
                Menu {
                    Button("main") {}
                    Button("feature/checkout") {}
                } label: {
                    Label(status.branch.head ?? "detached", systemImage: "arrow.triangle.branch")
                }
                .menuStyle(.button)
                .buttonStyle(.accessoryBar)
                .fixedSize()
                if status.hasChanges, status.syncState != .upToDate {
                    SyncChip(state: status.syncState).labelStyle(.compactIcon).font(.subheadline)
                }
                Spacer(minLength: 8)
                if !status.hasChanges { quietButton(protected: protected) }
                moreButton
            }
        }
    }

    @ViewBuilder
    private func quietButton(protected: Bool) -> some View {
        switch repo.primaryAction {
        case .publish:
            Button("Publish Branch", systemImage: "icloud.and.arrow.up") {}
                .buttonStyle(.bordered)
        case .sync(let a, let b):
            Button {} label: {
                Label(QuietPrimaryButton.syncTitle(ahead: a, behind: b), systemImage: "arrow.triangle.2.circlepath")
                    .monospacedDigit()
            }
            .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }

    private var moreButton: some View {
        Menu {
            Button("Fetch") {}
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .controlSize(.large)
        .fixedSize()
    }

    // MARK: Composer

    private var commitTitle: String {
        let all = if case .commit(let all) = repo.primaryAction { all } else { false }
        let base = all ? "Commit All" : "Commit"
        return repo.isProtectedBranch ? "\(base) to \(repo.status?.branch.head ?? "main")" : base
    }

    private var splitButton: some View {
        Menu {
            Button("Commit & Push") {}
            Button("Commit & Sync") {}
            Divider()
            Button("Amend Last Commit") {}
            Button("Undo Last Commit") {}
        } label: {
            Text(commitTitle)
        } primaryAction: {}
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .fixedSize()
    }

    @ViewBuilder
    private var composerView: some View {
        @Bindable var repo = repo
        switch composer {
        case .inline:
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Commit message", text: $repo.message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                Button("Write Message", systemImage: "sparkles") {}
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                splitButton
            }
        case .stacked:
            VStack(spacing: 8) {
                TextField("Commit message", text: $repo.message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                Menu {
                    Button("Commit & Push") {}
                } label: {
                    Text(commitTitle).frame(maxWidth: .infinity)
                } primaryAction: {}
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        case .trailing:
            VStack(alignment: .trailing, spacing: 8) {
                TextField("Commit message", text: $repo.message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...8)
                HStack {
                    Button("Write Message", systemImage: "sparkles") {}
                        .buttonStyle(.borderless)
                    Spacer()
                    splitButton
                }
            }
        }
    }

    // MARK: Rows

    private func group(_ title: String, _ files: [FileChange], action: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(files.count)").font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
            }
            .frame(height: 22)
            ForEach(files) { file in row(file, action: action) }
        }
    }

    @ViewBuilder
    private func row(_ file: FileChange, action: String) -> some View {
        switch rows {
        case .letterLeads:
            HStack(spacing: 8) {
                Text(file.kind.letter)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(file.kind.tint)
                    .frame(width: 14)
                Text(file.fileName).strikethrough(file.kind == .deleted, color: .secondary).lineLimit(1)
                Text(file.directory).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: action).foregroundStyle(.secondary).opacity(file.path.hasPrefix("src/lib/cart/total") ? 1 : 0)
            }
            .frame(height: 26)
            .padding(.leading, 4)
        case .iconTrailing:
            HStack(spacing: 8) {
                // The status letter stands in for the file icon here.
                Text(file.kind.letter)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(file.kind.tint)
                    .frame(width: 18)
                Text(file.fileName).lineLimit(1)
                Text(file.directory).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 4)
            }
            .frame(height: 28)
        case .letterTrailing:
            HStack(spacing: 6) {
                Text(file.fileName).lineLimit(1)
                Text(file.directory).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                Text(file.kind.letter)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(file.kind.tint)
                Spacer(minLength: 4)
            }
            .frame(height: 24)
            .padding(.leading, 18)
        }
    }
}
#endif

#if DEBUG
/// Control experiments: which system split-button and field styles exist, and at which sizes.
struct DES6ControlLab: View {
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach([ControlSize.regular, .large, .extraLarge], id: \.self) { size in
                HStack(spacing: 12) {
                    Text("\(String(describing: size))").frame(width: 90, alignment: .leading)
                    menu("prominent").buttonStyle(.borderedProminent)
                    menu("prominent+tint").buttonStyle(.borderedProminent).tint(.accentColor)
                    menu("bordered").buttonStyle(.bordered)
                    menu("default").keyboardShortcut(.defaultAction)
                    Menu {
                        Button("Commit & Push") {}
                    } label: {
                        Text("tinted label").foregroundStyle(.tint)
                    } primaryAction: {}
                    .menuStyle(.button).buttonStyle(.bordered).fixedSize()
                    Menu {
                        Button("Commit & Push") {}
                    } label: {
                        Label("Commit", systemImage: "checkmark").foregroundStyle(.tint)
                    } primaryAction: {}
                    .menuStyle(.button).fixedSize()
                    Button("Button prominent") {}.buttonStyle(.borderedProminent)
                    ControlGroup {
                        Button("Group") {}
                        Menu("") { Button("x") {} }
                    }
                    .fixedSize()
                    TextField("roundedBorder", text: $text).textFieldStyle(.roundedBorder).frame(width: 140)
                    TextField("squareBorder", text: $text).textFieldStyle(.squareBorder).frame(width: 140)
                    TextField("automatic", text: $text).frame(width: 140)
                }
                .controlSize(size)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func menu(_ title: String) -> some View {
        Menu {
            Button("Commit & Push") {}
        } label: {
            Text(title)
        } primaryAction: {}
        .menuStyle(.button)
        .fixedSize()
    }
}
#endif

#if DEBUG
/// A proposed repo card, drawn standalone so it can be judged before the real views change.
struct ChosenBoard: View {
    @State private var projects = SampleData.projects()

    var body: some View {
        let repos = projects.flatMap(\.repos)
        let web = repos.first { $0.name == "harbor-web" }!
        let api = repos.first { $0.name == "harbor-api" }!
        let atlas = repos.first { $0.name == "atlas" }!
        let ios = repos.first { $0.name == "harbor-ios" }!
        let docs = repos.first { $0.name == "harbor-docs" }!
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Narrow (sidebar hidden)").font(.title3.weight(.semibold))
                ChosenCard(repo: atlas)
                ChosenCard(repo: api)
                ChosenCard(repo: web)
                ChosenCard(repo: ios)
            }
            .frame(width: 408)
            VStack(alignment: .leading, spacing: 10) {
                Text("Wide").font(.title3.weight(.semibold))
                ChosenCard(repo: api)
                ChosenCard(repo: web, busy: true)
                ChosenCard(repo: web, problem: RepoProblem(message: "The pre-commit hook stopped the commit. Its output says what to fix.", fixes: [.showOutput]))
                ChosenCard(repo: docs)
            }
            .frame(width: 780)
            VStack(alignment: .leading, spacing: 10) {
                Text("Today").font(.title3.weight(.semibold))
                RepoSection(repo: api, projectCaption: "Harbor")
                RepoSection(repo: atlas, projectCaption: "Atlas")
            }
            .frame(width: 408)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}

struct ChosenCard: View {
    @Bindable var repo: RepoItem
    var busy = false
    var problem: RepoProblem?

    var body: some View {
        let status = repo.status!
        VStack(alignment: .leading, spacing: 0) {
            header(status)
            if let problem {
                banner(problem).padding(.top, 12)
            }
            if status.hasChanges {
                composer.padding(.top, 12)
                VStack(alignment: .leading, spacing: 10) {
                    if !status.staged.isEmpty { group("Staged", status.staged, action: "minus") }
                    let changes = status.unstaged + status.untracked
                    if !changes.isEmpty { group(status.staged.isEmpty ? "Changes" : "Not Staged", changes, action: "plus") }
                }
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func header(_ status: RepoStatus) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text(repo.name).font(.headline).lineLimit(1).layoutPriority(2)
                .padding(.trailing, 4)
            Button {} label: {
                Label(status.branch.head ?? "detached", systemImage: "arrow.triangle.branch")
                    .lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.accessoryBar)
            .foregroundStyle(.secondary)
            if status.hasChanges, status.syncState != .upToDate {
                SyncChip(state: status.syncState).labelStyle(.compactIcon)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !status.hasChanges {
                switch repo.primaryAction {
                case .publish:
                    ViewThatFits {
                        Button("Publish Branch", systemImage: "icloud.and.arrow.up") {}
                        Button("Publish", systemImage: "icloud.and.arrow.up") {}
                    }
                case .sync(let a, let b):
                    Button {} label: {
                        Label(QuietPrimaryButton.syncTitle(ahead: a, behind: b), systemImage: "arrow.triangle.2.circlepath").monospacedDigit()
                    }
                default: EmptyView()
                }
            }
            Menu {
                Button("Fetch") {}
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
        }
        .buttonStyle(.bordered)
    }

    private var commitTitle: String {
        if busy { return "Committing…" }
        let all = if case .commit(let all) = repo.primaryAction { all } else { false }
        let base = all ? "Commit All" : "Commit"
        return repo.isProtectedBranch ? "\(base) to \(repo.status?.branch.head ?? "main")" : base
    }

    private var split: some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.small) }
            Menu {
                Button("Commit & Push") {}
                Button("Commit & Sync") {}
                Divider()
                Button("Amend Last Commit") {}
                Button("Undo Last Commit") {}
            } label: {
                Text(commitTitle)
            } primaryAction: {}
            .menuStyle(.button)
            .fixedSize()
            .disabled(busy)
        }
    }

    private var sparkle: some View {
        Button("Generate Message", systemImage: "sparkles") {}
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Generate Message (⌥⌘G)")
    }

    private var composer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 8) {
                field.frame(minWidth: 170, idealWidth: 170, maxWidth: .infinity)
                sparkle
                split
            }
            VStack(alignment: .leading, spacing: 8) {
                field
                HStack {
                    sparkle
                    Spacer()
                    split
                }
            }
        }
    }

    private var field: some View {
        TextField("Commit message", text: $repo.message, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...8)
    }

    private func banner(_ problem: RepoProblem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: problem.isWarning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundStyle(problem.isWarning ? .orange : .red)
            Text(problem.message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Show Output") {}.controlSize(.small)
            Button("Dismiss", systemImage: "xmark") {}.labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func group(_ title: String, _ files: [FileChange], action: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 14)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(files.count)").font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
            }
            .frame(height: 24)
            ForEach(files) { file in
                HStack(spacing: 6) {
                    Text(file.kind.letter)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(file.kind.tint)
                        .frame(width: 14)
                    Text(file.fileName).strikethrough(file.kind == .deleted, color: .secondary).lineLimit(1).layoutPriority(1)
                    Text(file.directory).font(.callout).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: action).foregroundStyle(.secondary).frame(width: 22, height: 22)
                        .opacity(file.fileName == "total.ts" || file.fileName == "service.py" ? 1 : 0)
                }
                .frame(height: 26)
                .background(file.fileName == "total.ts" ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}
#endif

#if DEBUG
/// Layout question: does every repo with changes stay open, or only the current one?
struct AccordionBoard: View {
    @State private var projects = SampleData.projects()

    var body: some View {
        let repos = projects.flatMap(\.repos)
        let active = repos.filter(\.needsAttention)
        let current = active.first { $0.name == "harbor-web" }!
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("1 · Every repo with changes open (today)").font(.title3.weight(.semibold))
                ForEach(active) { ChosenCard(repo: $0) }
            }
            .frame(width: 408)
            VStack(alignment: .leading, spacing: 10) {
                Text("2 · Only the current repo open").font(.title3.weight(.semibold))
                ForEach(active) { repo in
                    if repo === current {
                        ChosenCard(repo: repo)
                    } else if repo.status?.hasChanges == true {
                        ClosedDirtyRow(repo: repo)
                    } else {
                        ChosenCard(repo: repo)
                    }
                }
            }
            .frame(width: 408)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}

struct ClosedDirtyRow: View {
    var repo: RepoItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            Text(repo.name).font(.headline)
            Label(repo.status?.branch.head ?? "", systemImage: "arrow.triangle.branch").foregroundStyle(.secondary).labelStyle(.compactIcon)
            Spacer()
            Text("\(repo.status?.changedPathCount ?? 0) changes").foregroundStyle(.secondary)
            Image(systemName: "ellipsis").frame(width: 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
#endif
