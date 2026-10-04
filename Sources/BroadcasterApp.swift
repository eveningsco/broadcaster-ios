import SwiftUI

@main
struct BroadcasterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.isLoggedIn {
                    HomeView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(model)
            // Evenings is dark-only: Info.plist's UIUserInterfaceStyle=Dark
            // covers UIKit-hosted chrome (alerts, sheets, menus); this covers
            // the SwiftUI tree so previews and any future host agree.
            .preferredColorScheme(.dark)
        }
    }
}
