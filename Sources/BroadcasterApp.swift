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
        }
    }
}
