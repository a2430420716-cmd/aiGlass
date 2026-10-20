import SwiftUI

struct DataStorageSettingsView: View {
    var onSelect: ((DataStorageRegion) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRegion = AppSettings.dataStorageRegion

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.t("数据存储服务器", "Data Storage Server"))
                        .font(AppTheme.notoSansSC(size: 22, weight: .bold))
                        .foregroundStyle(AppTheme.primaryText)

                    Text(L10n.t("选择中国大陆使用国内服务器，选择其他地区使用海外服务器。国内与海外服务器的账号和数据相互独立。", "Select Mainland China to use the China server. All other regions use the overseas server. Accounts and data are independent between these two servers."))
                        .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(4)

                    VStack(spacing: 12) {
                        ForEach(DataStorageRegion.allCases) { region in
                            Button {
                                selectedRegion = region
                                AppSettings.dataStorageRegion = region
                                onSelect?(region)
                            } label: {
                                SettingsSelectionRow(
                                    title: region.title,
                                    isSelected: selectedRegion == region
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
    }

    private var navigationBar: some View {
        HStack {
            if onSelect == nil {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

#Preview {
    CompatibleNavigationStack {
        DataStorageSettingsView()
    }
}
