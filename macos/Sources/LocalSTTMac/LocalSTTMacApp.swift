import SwiftUI

/// App delegate manages activation and ensures the main window opens on launch.
///
/// Known issue: MenuBarExtra(.window) + WindowGroup on macOS 14+ doesn't auto-create
/// the WindowGroup's window. We force it open from applicationDidFinishLaunching.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Force the WindowGroup to create its initial window after a brief delay
        // (SwiftUI scenes need a run loop tick to initialize)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if !NSApp.windows.contains(where: { $0.canBecomeMain }) {
                NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
            }
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't terminate — switch to accessory (menu bar only)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }
}

@main
struct LocalSTTMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = MacAppState()

    var body: some Scene {
        // Main window first — plain WindowGroup auto-creates on launch
        WindowGroup(id: "main") {
            MainWindowView()
                .environment(appState)
                .frame(minWidth: 480, minHeight: 520)
        }
        .defaultSize(width: 520, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        // Menu bar icon with popover
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        // Settings (Cmd+,)
        Settings {
            MacSettingsView()
                .environment(appState)
        }
    }

    private var menuBarIcon: String {
        switch appState.state {
        case .recording: return "mic.fill"
        case .transcribing: return "ellipsis.circle"
        default: return "mic"
        }
    }
}
