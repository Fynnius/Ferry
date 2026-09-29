import SwiftUI

/// The sparkle next to the message field: writes a message from the changes; while running
/// it animates and a second click (or ⎋) cancels.
struct AIMessageButton: View {
    var repo: RepoItem
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        Button {
            if repo.isGeneratingMessage {
                app?.cancelMessageGeneration(for: repo)
            } else {
                app?.generateMessage(for: repo)
            }
        } label: {
            Image(systemName: repo.isGeneratingMessage ? "stop.circle" : "sparkles")
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.variableColor.iterative, isActive: repo.isGeneratingMessage && !Motion.reduceMotion)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .keyboardShortcut(repo.isGeneratingMessage ? .cancelAction : nil)
        .help(repo.isGeneratingMessage ? "Stop writing (⎋)" : "Write a message from the changes (⌥⌘G)")
        .accessibilityLabel(repo.isGeneratingMessage ? "Stop generating message" : "Generate commit message")
    }
}
