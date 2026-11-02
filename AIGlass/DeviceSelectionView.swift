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
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(models) { model in
                            Button {
                                pairingCoordinator.selectDevice(model, guideItems: [])
                                if model.prepare?
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty != false {
                                    Task {
                                        await refreshSelectedModel(modelName: model.modelName)
                                    }
                                }
                            } label: {
                                deviceCard(model)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
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
            Text(L10n.t("选择配对设备", "Select Device"))
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

    private func deviceCard(_ model: DeviceModelItem) -> some View {
        VStack(spacing: 10) {
            Image(model.fallbackImageName)
                .resizable()
                .scaledToFit()
                .frame(height: 78)

            VStack(spacing: 4) {
                Text(deviceSeriesName(for: model))
                    .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.primaryText)

                if !model.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(deviceModelName(for: model))
                        .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.primaryText)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .frame(minHeight: 184)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        .shadow(color: AppTheme.cardShadow, radius: 10, y: 4)
    }

    /// 产品名来自接口；已识别型号使用完整展示名，接口请求仍保留原始 modelName。
    private func deviceSeriesName(for model: DeviceModelItem) -> String {
        let eqName = model.eqName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eqName.isEmpty else { return L10n.t("AI 眼镜", "AI Glasses") }
        return "\(eqName) AI Glasses"
    }

    private func deviceModelName(for model: DeviceModelItem) -> String {
        switch model.glassDeviceModel {
        case .luminaL1, .astraA1:
            return model.glassDeviceModel.rawValue
        case .unknown:
            return model.modelName
        }
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
