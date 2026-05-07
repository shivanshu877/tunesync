import SwiftUI

@main
struct TuneSyncApp: App {
    @StateObject private var rt = AppRuntime()

    var body: some Scene {
        WindowGroup("TuneSync") {
            ContentView(rt: rt)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    rt.updater.checkInteractive()
                }
                .keyboardShortcut("u", modifiers: [.command])
            }
        }
    }
}
