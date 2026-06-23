import SwiftUI

struct RootRouter: View {
    @Environment(APIClient.self) private var api

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
