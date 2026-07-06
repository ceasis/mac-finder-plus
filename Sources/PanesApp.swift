import SwiftUI

@main
struct PanesApp: App {
    @State private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 780, minHeight: 480)
        }
        .commands {
            AppCommands(appState: appState)
        }
    }
}
