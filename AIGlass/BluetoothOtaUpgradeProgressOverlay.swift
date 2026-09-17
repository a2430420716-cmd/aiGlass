import SwiftUI

struct BluetoothOtaUpgradeProgressOverlay: View {
    let state: BluetoothOtaUpgradeState
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Text(title)
                    .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.primaryText)

                if let progress = progressValue {
                    ProgressView(value: progress)
                        .tint(AppTheme.primaryText)
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView()
                        .tint(AppTheme.primaryText)
                }

                Text(state.statusText)
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)

                if showsDismissButton {
                    Button(action: onDismiss) {
                        Text(L10n.t("知道了", "Got It"))
                            .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 320)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var title: String {
        switch state {
        case .completed:
            return L10n.t("升级完成", "Update Complete")
        case .failed:
            return L10n.t("升级失败", "Update Failed")
        default:
            return L10n.t("蓝牙固件升级", "Bluetooth Firmware Update")
        }
    }

    private var progressValue: Double? {
        switch state {
        case .downloadingFirmware(let percent),
             .uploadingFirmware(let percent),
             .upgrading(let percent):
            return Double(percent) / 100
        default:
            return nil
        }
    }

    private var showsDismissButton: Bool {
        switch state {
        case .completed, .failed:
            return true
        default:
            return false
        }
    }
}
