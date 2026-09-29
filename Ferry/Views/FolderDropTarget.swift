import SwiftUI

/// Accepts folders dragged in from Finder and hands them to `AppModel.openFolders`, the
/// same path as the Dock icon and the Finder service. While a drag hovers, a quiet accent
/// outline shows where it lands. Keyboard and VoiceOver users have File ▸ Add Folder….
struct FolderDropTarget: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var isTargeted = false
    var cornerRadius: CGFloat = 10
    var inset: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                app.openFolders(urls)
            } isTargeted: { targeted in
                withAnimation(Motion.snappy) { isTargeted = targeted }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: cornerRadius))
                        .padding(inset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    func folderDropTarget(cornerRadius: CGFloat = 10, inset: CGFloat = 6) -> some View {
        modifier(FolderDropTarget(cornerRadius: cornerRadius, inset: inset))
    }
}
