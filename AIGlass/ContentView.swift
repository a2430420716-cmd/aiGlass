import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authSession: AuthSession
    @ObservedObject private var languageManager = AppLanguageManager.shared

    @State private var serverReady = false
    @State private var serverError: String?
    @State private var dispatchAttempt = 0

    var body: some View {
        ZStack {
            Group {
                if authSession.isLoggedIn {
                    MainTabView()
                } else if !serverReady {
                    VStack(spacing: 16) {
                        if let serverError {
                            Text(serverError)
                                .multilineTextAlignment(.center)
                            Button(L10n.t("重试", "Retry")) { dispatchAttempt += 1 }
                        } else {
                            ProgressView(L10n.t("正在连接服务器", "Connecting to server"))
                        }
                    }
                    .padding(24)
                    .task(id: dispatchAttempt) {
                        serverError = nil
                        do {
                            try await ServerDispatch.resolveBeforeLogin()
                            try Task.checkCancellation()
                            serverReady = true
                        } catch is CancellationError {
                            // The view may disappear during login restoration.
                        } catch {
                            serverError = L10n.t("无法确认服务区域，请检查网络后重试。", "Unable to determine the service region. Check your network and try again.")
                        }
                    }
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
