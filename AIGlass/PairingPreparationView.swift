import SwiftUI

/// 配对准备页展示方式。改 `current` 即可在原生 UI 与 WebView 之间切换。
enum PairingPreparationDisplayMode {
    /// 原生 SwiftUI + `get_device_guide` 接口
    case nativeGuide
    /// WebView 渲染型号列表里的 `prepare` HTML
    case htmlWebView

    static let current: Self = .htmlWebView
}

struct PairingPreparationView: View {
    let onBack: () -> Void

    @EnvironmentObject private var pairingCoordinator: PairingCoordinator
    @EnvironmentObject private var authSession: AuthSession

    @State private var guideItems: [DeviceGuideItem] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var webLoadFailed = false

    var body: some View {
        Group {
            switch PairingPreparationDisplayMode.current {
            case .nativeGuide:
                nativeGuideContent
            case .htmlWebView:
                htmlWebViewContent
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    // MARK: - Native guide (get_device_guide)

    private var nativeGuideContent: some View {
        VStack(spacing: 0) {
            navigationBar

            if isLoading && guideItems.isEmpty {
                Spacer()
                ProgressView(L10n.t("加载配对准备...", "Loading pairing prep..."))
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
            } else if let loadError, guideItems.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Text(loadError)
                        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button(L10n.t("重新加载", "Reload")) {
                        Task { await loadGuideItems() }
                    }
                    .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
                }
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(Array(guideItems.enumerated()), id: \.element.id) { index, item in
                            guideStepView(index: index, item: item)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }

            startPairingButton(disabled: guideItems.isEmpty && isLoading)
        }
        .task {
            guideItems = pairingCoordinator.selectedGuideItems
            if guideItems.isEmpty {
                await loadGuideItems()
            }
        }
    }

    // MARK: - WebView (model.prepare HTML)

    private var htmlWebViewContent: some View {
        VStack(spacing: 0) {
            navigationBar

            if hasPrepareHTML && !webLoadFailed {
                HTMLWebView(
                    html: prepareHTML,
                    textStyle: .pairingInstructions,
                    onLoadResult: { success in
                        if !success {
                            webLoadFailed = true
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fallbackInstructions
            }

            startPairingButton(disabled: false)
        }
        .onAppear {
            let html = pairingCoordinator.selectedPrepareHTML ?? ""
            print("[PairingPreparation] webview model=\(pairingCoordinator.selectedAPIModelName ?? "") eq=\(pairingCoordinator.selectedEqName ?? "") prepare_length=\(html.count)")
        }
        .onChangeCompat(of: pairingCoordinator.selectedPrepareHTML) { _ in
            webLoadFailed = false
        }
    }

    private var hasPrepareHTML: Bool {
        !prepareHTML.isEmpty
    }

    private var prepareHTML: String {
        pairingCoordinator.selectedPrepareHTML?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Android `ll_instructions` 同款本地兜底：prepare 为空或 WebView 加载失败时显示。
    private var fallbackInstructions: some View {
        ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 28) {
                fallbackStep(
                    title: L10n.t("一、将眼镜开机", "1. Power on the glasses"),
                    imageName: "pairing_power_on_1",
                    description: L10n.t(
                        "拨动电源键开机，内侧指示灯会开始闪烁。开机完成时，指示灯熄灭且听到语音提示(若无反应，请先尝试为眼镜充电)。",
                        "Slide the power switch to turn on the glasses. The inner LED blinks while starting, then turns off when startup completes. If nothing happens, charge the glasses first."
                    )
                )
                fallbackStep(
                    title: L10n.t("二、确认内侧指示灯闪烁", "2. Confirm the inner LED is blinking"),
                    imageName: "pairing_inner_indicator",
                    description: L10n.t(
                        "指示灯闪烁说明进入配对状态。",
                        "A blinking LED means the glasses are in pairing mode."
                    )
                )
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fallbackStep(
        title: String,
        imageName: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                .foregroundStyle(Color(red: 0.20, green: 0.20, blue: 0.20))

            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)

            Text(description)
                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                .foregroundStyle(.black)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("眼镜配对准备", "Glasses Pairing Preparation"))
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

    private func startPairingButton(disabled: Bool) -> some View {
        Button {
            pairingCoordinator.startPairing()
        } label: {
            Text(L10n.t("开始配对", "Start Pairing"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
        .disabled(disabled)
    }

    private func guideStepView(index: Int, item: DeviceGuideItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t(
                "\(chineseNumeral(for: index))、\(item.title)",
                "\(index + 1). \(item.title)"
            ))
                .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            guideImage(urlString: item.image)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: AppTheme.cardShadow, radius: 8, y: 2)

            Text(item.type)
                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func guideImage(urlString: String) -> some View {
        if let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal, 12)
                case .failure:
                    imagePlaceholder
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 160)
                @unknown default:
                    imagePlaceholder
                }
            }
        } else {
            imagePlaceholder
        }
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(red: 0.94, green: 0.94, blue: 0.94))
            .frame(height: 160)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(AppTheme.secondaryText)
            }
    }

    private func loadGuideItems() async {
        guard let modelName = pairingCoordinator.selectedAPIModelName else {
            loadError = L10n.t("未选择设备型号", "No device model selected")
            return
        }

        isLoading = true
        loadError = nil

        do {
            let items = try await DeviceService.fetchDeviceGuide(
                modelName: modelName,
                token: authSession.token
            )
            guideItems = items
            isLoading = false
        } catch {
            isLoading = false
            loadError = error.localizedDescription
            print("[get_device_guide] preparation load error: \(error.localizedDescription)")
        }
    }

    private func chineseNumeral(for index: Int) -> String {
        let numerals = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        guard index >= 0, index < numerals.count else { return "\(index + 1)" }
        return numerals[index]
    }
}

#Preview {
    CompatibleNavigationStack {
        PairingPreparationView(onBack: {})
            .environmentObject(PairingCoordinator())
            .environmentObject(AuthSession())
    }
}
