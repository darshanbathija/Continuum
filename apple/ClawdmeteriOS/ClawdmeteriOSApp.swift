import SwiftUI
import ClawdmeterShared

@main
struct ClawdmeteriOSApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(nil) // honor system theme by default
        }
    }
}
