import SwiftUI

@main
struct WhisperSRTApp: App {
    @State private var showAbout = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 560, minHeight: 400)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About WhisperSRT") { showAbout = true }
            }
        }
    }
}
