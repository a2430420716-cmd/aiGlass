import SwiftUI

struct PairDeviceView: View {
    let onBack: () -> Void

    @EnvironmentObject private var pairingCoordinator: PairingCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("pair_device_glasses")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)

            Spacer()

            Button {
                pairingCoordinator.goToPreparation()
            } label: {
                Text(L10n.t("去配对", "Start Pairing"))
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            AppTheme.background.ignoresSafeArea()
            Image("bg")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .compatibleToolbarBackgroundHidden()
    }
}

#Preview {
    CompatibleNavigationStack {
        PairDeviceView(onBack: {})
            .environmentObject(PairingCoordinator())
    }
}
