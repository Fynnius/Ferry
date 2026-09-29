import SwiftUI
import FerryKit

/// Suggested projects for the repos in Other Repositories. The user ticks the ones to
/// keep; nothing changes until they press Create. Present it from anywhere as a sheet.
struct GroupSuggestionsSheet: View {
    var suggester: any GroupSuggesting = AppleIntelligenceGrouper()
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.loading
    @State private var accepted: Set<String> = []

    private enum Phase {
        case loading
        case done([GroupSuggestion])
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Suggested Groups").font(.headline)
                Text("From the names in Other Repositories, by Apple Intelligence on this Mac. Nothing leaves it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if case .failed = phase {
                    Button("Try Again") { Task { await load() } }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(createTitle) {
                    app.createProjects(from: suggestions.filter { accepted.contains($0.id) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(accepted.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 320, idealHeight: 440)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Looking at \(app.grouping.other.count) repo names…")
        case .failed(let message):
            ContentUnavailableView("No suggestions", systemImage: "exclamationmark.triangle", description: Text(message))
        case .done(let suggestions) where suggestions.isEmpty:
            ContentUnavailableView("No clear groups", systemImage: "square.stack.3d.up.slash", description: Text("None of these repos obviously belong together. You can still move them from each repo's … menu."))
        case .done(let suggestions):
            List(suggestions) { suggestion in
                Toggle(isOn: binding(for: suggestion)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.name)
                        Text(suggestion.members.map(\.label).formatted(.list(type: .and)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityHint("Creates the project \(suggestion.name) with these repos")
            }
            .listStyle(.bordered)
        }
    }

    private var suggestions: [GroupSuggestion] {
        if case .done(let suggestions) = phase { return suggestions }
        return []
    }

    private var createTitle: String {
        accepted.count == 1 ? "Create 1 Project" : accepted.isEmpty ? "Create Projects" : "Create \(accepted.count) Projects"
    }

    private func binding(for suggestion: GroupSuggestion) -> Binding<Bool> {
        Binding {
            accepted.contains(suggestion.id)
        } set: { isOn in
            if isOn { accepted.insert(suggestion.id) } else { accepted.remove(suggestion.id) }
        }
    }

    private func load() async {
        phase = .loading
        accepted = []
        do {
            phase = .done(try await GroupSuggestions.suggest(for: app.grouping.other, using: suggester))
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// "Suggest Groups…" with its sheet, or a one-line reason when Apple Intelligence can't
/// run. Nothing at all on Macs that can never run it, or with fewer than two leftovers.
struct SuggestGroupsButton: View {
    @Environment(AppModel.self) private var app
    @State private var showsSheet = false

    var body: some View {
        if AppleIntelligence.isAvailable {
            Button("Suggest Groups…") { showsSheet = true }
                .disabled(app.grouping.other.count < 2)
                .help("Let Apple Intelligence on this Mac propose projects for Other Repositories")
                .sheet(isPresented: $showsSheet) { GroupSuggestionsSheet() }
        } else if let reason = AppleIntelligence.unavailableReason {
            Text(reason).foregroundStyle(.secondary)
        }
    }
}
