import SwiftUI

@main
struct NeuroDeskAIApp: App {
    @StateObject private var viewModel = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView_Hybrid()
                .environmentObject(viewModel)
                // Explicit tint matches AccentColor asset (HSB: 0.72, 0.6, 1.0)
                // This coexists with the AccentColor in Assets.xcassets to ensure consistent theming.
                .tint(.appAccent)
        }
        .windowStyle(.automatic)
    }
}

private extension Color {
    // Centralized app accent color used via .tint(.appAccent)
    // Matches the AccentColor asset to avoid visual mismatch.
    static let appAccent = Color(hue: 0.72, saturation: 0.6, brightness: 1.0)
}
