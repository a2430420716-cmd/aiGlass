import SwiftUI

struct DeviceSelectionView: View {
    let onBack: () -> Void

    @EnvironmentObject private var pairingCoordinator: PairingCoordinator
    @EnvironmentObject private var authSession: AuthSession

    @State private var models: [DeviceModelItem] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            if isLoading {
                Spacer()
                ProgressView(L10n.t("加载设备型号...", "Loading models..."))
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
            } else if let loadError {
                Spacer()
                VStack(spacing: 16) {
                    Text(loadError)
                        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button(L10n.t("重新加载", "Reload")) {
                        Task { await loadModels() }
                    }
                    .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
                }
                Spacer()
            } else {
                GeometryReader { geometry in
                    // Android uses 300px cards and 25px gaps on its 720px design grid.
                    // Fit four rows when space permits; smaller screens can still scroll.
                    let scale = geometry.size.width / 720
                    let cardSpacing = 25 * scale
                    let listPadding = 25 * scale
                    let availableRowHeight = (geometry.size.height - listPadding * 2 - cardSpacing * 3) / 4
                    let cardHeight = max(128, min(300 * scale, availableRowHeight))

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: cardSpacing) {
                            ForEach(models) { model in
                                Button {
                                    pairingCoordinator.selectDevice(model, guideItems: [])
                                    if model.localizedPrepareHTML == nil {
                                        Task {
                                            await refreshSelectedModel(modelName: model.modelName)
                                        }
                                    }
                                } label: {
                                    deviceCard(model, height: cardHeight)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, listPadding)
                    }
                }
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .task {
            await loadModels()
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("选择配对设备", "Select a device to pair"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 44, alignment: .leading)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func deviceCard(_ model: DeviceModelItem, height: CGFloat) -> some View {
        VStack(spacing: 12) {
            Image(model.fallbackImageName)
                .resizable()
                .scaledToFit()
                .frame(height: min(56, max(36, height - 100)))

            VStack(spacing: 5) {
                Text(deviceSeriesName(for: model))
                    .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if !model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(model.displayName)
                        .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        .shadow(color: AppTheme.cardShadow, radius: 10, y: 4)
    }

    /// 品牌来自接口；型号展示使用 model_name_alias，配对和请求保留原始 modelName。
    private func deviceSeriesName(for model: DeviceModelItem) -> String {
        let eqName = model.eqName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eqName.isEmpty else { return L10n.t("AI 眼镜", "AI Glasses") }
        return "\(eqName) AI Glasses"
    }

    private func loadModels() async {
        isLoading = true
        loadError = nil

        do {
            let list = try await DeviceService.fetchDeviceModelList(token: authSession.token)
            // status=1 为启用；若字段缺失则保留
            models = list
                .filter { $0.status == nil || $0.status == 1 }
                .sorted { ($0.sort ?? 0) > ($1.sort ?? 0) }
            isLoading = false
        } catch {
            isLoading = false
            loadError = error.localizedDescription
            print("[get_device_model_list] error: \(error.localizedDescription)")
        }
    }

    private func refreshSelectedModel(modelName: String) async {
        do {
            if let refreshed = try await DeviceService.fetchDeviceModel(
                modelName: modelName,
                token: authSession.token
            ) {
                pairingCoordinator.refreshSelectedDeviceModel(refreshed)
            }
        } catch {
            // 与 Android 一致：单型号刷新失败不阻断配对，准备页自动显示本地 fallback。
            print("[get_device_model] model_name=\(modelName) error: \(error.localizedDescription)")
        }
    }
}

#Preview {
    CompatibleNavigationStack {
        DeviceSelectionView(onBack: {})
            .environmentObject(PairingCoordinator())
            .environmentObject(AuthSession())
    }
}
