import SwiftUI
import TuneSyncCore

@main
struct TuneSyncApp: App {
    var body: some Scene {
        WindowGroup("TuneSync") {
            Text("TuneSync \(TuneSyncCore.version)")
                .frame(minWidth: 400, minHeight: 200)
        }
    }
}
