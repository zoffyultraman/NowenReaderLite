import SwiftUI

struct RootRouter: View {
    @ObservedObject private var api = APIClient.shared

    enum Route {
        case serverConfig
        case login
        case main
    }

    var body: some View {
        Group {
            if api.serverURL.isEmpty {
                ServerConfigView(onConnected: {})

            } else if !api.isLoggedIn {
                LoginView(onLoginSuccess: {})
            } else {
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: api.serverURL.isEmpty)
        .animation(.easeInOut(duration: 0.3), value: api.isLoggedIn)
    }
}
