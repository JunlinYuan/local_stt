import SwiftUI

@main
struct LocalSTTApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RecordingView()
                .environment(appState)
        }
    }
}
