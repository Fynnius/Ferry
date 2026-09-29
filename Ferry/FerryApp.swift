import SwiftUI
import FerryKit

@main
struct FerryApp: App {
    @State private var app = AppModel()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // Launched by git to ask for a credential: show the prompt and exit, no app.
        if AskpassHelper.isAskpassInvocation {
            AskpassHelper.runAndExit()
        }
        // As an XCTest host Ferry stays invisible: no Dock icon, no window, never takes focus.
        if Self.isTestHost {
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
    }

    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        Window("Ferry", id: "main") {
            root
                .environment(app)
                .onAppear {
                    delegate.keepsRunningWithoutWindows = { [settings = app.settings] in settings.showMenuBarExtra }
                }
                .modifier(ConnectsAppDelegate(delegate: delegate, app: app))
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(isMockup ? .contentSize : .automatic)
        .commands {
            FerryCommands(app: app)
        }

        Settings {
            SettingsView()
                .environment(app)
        }

        MenuBarExtra(isInserted: Binding(get: { app.settings.showMenuBarExtra }, set: { app.settings.showMenuBarExtra = $0 })) {
            MenuBarContent()
                .environment(app)
        } label: {
            MenuBarLabel()
                .environment(app)
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if let layout = UserDefaults.standard.string(forKey: "FerryMockup").flatMap(MockupLayout.init(rawValue:)) {
            MockupRoot(layout: layout, narrow: UserDefaults.standard.bool(forKey: "FerryMockupNarrow"))
                .onAppear(perform: applyMockupAppearance)
        } else {
            MainWindow()
                .onAppear(perform: applyMockupAppearance)
        }
        #else
        MainWindow()
        #endif
    }

    private var isMockup: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: "FerryMockup") != nil
        #else
        false
        #endif
    }

    #if DEBUG
    /// Screenshot runs pass `-FerryMockupAppearance light|dark`.
    private func applyMockupAppearance() {
        guard let appearance = UserDefaults.standard.string(forKey: "FerryMockupAppearance") else { return }
        NSApp.activate()
        switch appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
    #endif
}
