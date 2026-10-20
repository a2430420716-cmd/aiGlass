import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authSession: AuthSession
    @ObservedObject private var languageManager = AppLanguageManager.shared

    @State private var serverReady = false
    var body: some View {
        ZStack {
            Group {
                if authSession.isLoggedIn {
                    MainTabView()
                } else if !serverReady {
                    CompatibleNavigationStack {
                        DataStorageSettingsView { region in
                            BackendRouting.selectRegionBeforeLogin(region)
                            serverReady = true
                        }
                    }
                } else {
                    LoginView(onSelectServer: { serverReady = false })
                        .id(languageManager.refreshID)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: authSession.isLoggedIn)
            .onChangeCompat(of: authSession.isLoggedIn) { loggedIn in
                if !loggedIn { serverReady = false }
            }

        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthSession())
        .environmentObject(PairingCoordinator())
}
