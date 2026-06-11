import SwiftUI

struct RootRouter: View {
    var body: some View {
        let api = APIClient.shared
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
