import SwiftUI

struct DataStorageSettingsView: View {
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

                    Text(L10n.t("为满足不同国家和地区法律法规要求，在您选择指定的地区后，您的个人数据将会完全存储在该地区。请注意，不同地区之间的数据完全独立。", "To comply with laws and regulations in different countries and regions, your personal data will be stored entirely in the region you select. Note that data in different regions is fully independent."))
                        .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(4)

                    VStack(spacing: 12) {
                        ForEach(DataStorageRegion.allCases) { region in
                            Button {
                                selectedRegion = region
                                AppSettings.dataStorageRegion = region
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
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 44, height: 44, alignment: .leading)
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
