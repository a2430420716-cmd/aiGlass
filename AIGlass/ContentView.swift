import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authSession: AuthSession
    @ObservedObject private var languageManager = AppLanguageManager.shared

    var body: some View {
        ZStack {
            Group {
                if authSession.isLoggedIn {
                    MainTabView()
                } else {
                    LoginView()
                        .id(languageManager.refreshID)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: authSession.isLoggedIn)

        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthSession())
        .environmentObject(PairingCoordinator())
}
