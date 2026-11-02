import SwiftUI

struct OperationGuideView: View {
    @Environment(\.dismiss) private var dismiss

    let modelName: String
    let token: String?

    @State private var guides: [DeviceOperationItem] = []
    @State private var selectedIndex = 0
    @State private var isLoading = true
    @State private var loadError: String?

    private var isLangZh: Bool {
        switch AppSettings.language {
        case .englishUS:
            return false
        case .simplifiedChinese:
            return true
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "zh"
            return !preferred.hasPrefix("en")
        }
    }

    private var currentGuide: DeviceOperationItem? {
        guard !guides.isEmpty, selectedIndex < guides.count else { return nil }
        return guides[selectedIndex]
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                navigationBar

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if let loadError, guides.isEmpty {
                    errorState(loadError)
                } else if guides.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            tabSwitcher
                                .padding(.top, 8)

                            Image(imageAssetName(for: currentGuide))
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 20)

                            ForEach(visibleSections(for: currentGuide)) { section in
                                sectionView(section)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                    }
                }
            }
        }
        .appNavigationPageBackground(AppTheme.background)
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .task {
            await loadData()
        }
    }

    /// 与眼镜设置、关于设备等二级页统一；避免系统 toolbar 在新版 iOS 自动添加玻璃圆形背景。
    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("操作指南", "Operation Guide"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(Array(guides.enumerated()), id: \.element.id) { index, guide in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedIndex = index
                    }
                } label: {
                    Text(displayGuideTitle(guide))
                        .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                        .foregroundStyle(selectedIndex == index ? .white : AppTheme.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            selectedIndex == index
                                ? Color(red: 0.20, green: 0.20, blue: 0.20)
                                : Color.clear
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(AppTheme.cardBackground)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(Color(red: 0.90, green: 0.90, blue: 0.90), lineWidth: 1)
        }
    }

    private func sectionView(_ section: DeviceOperationSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localizedTitle(section.title, en: section.enTitle))
                .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(section.children.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localizedTitle(item.title, en: item.enTitle))
                            .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                            .foregroundStyle(AppTheme.primaryText)

                        Text(localizedTitle(item.content, en: item.enContent))
                            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    if index < section.children.count - 1 {
                        Divider()
                            .overlay(Color(red: 0.94, green: 0.94, blue: 0.94))
                            .padding(.horizontal, 16)
                    }
                }
            }
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(L10n.t("暂无操作指南", "No operation guide"))
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text(message)
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task { await loadData() }
            } label: {
                Text(L10n.t("重试", "Retry"))
                    .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .frame(height: 40)
                    .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func loadData() async {
        isLoading = true
        loadError = nil

        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            applyFallback()
            isLoading = false
            return
        }

        do {
            let items = try await DeviceService.fetchDeviceOperation(modelName: name, token: token)
            if items.isEmpty {
                applyFallback()
            } else {
                guides = items
                selectedIndex = 0
            }
        } catch {
            print("[OperationGuide] load failed: \(error.localizedDescription)")
            applyFallback()
            // 有本地兜底时不挡页面；仅在兜底也空时展示错误。
            if guides.isEmpty {
                loadError = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func applyFallback() {
        guides = Self.fallbackGuides
        selectedIndex = 0
    }

    private func visibleSections(for guide: DeviceOperationItem?) -> [DeviceOperationSection] {
        (guide?.children ?? []).filter { !$0.children.isEmpty }
    }

    private func imageAssetName(for guide: DeviceOperationItem?) -> String {
        let title = guide?.title ?? ""
        // Android: 「功能键」用 guide_pic1，其它用 guide_pic3；iOS 对应本地示意图。
        if title.contains("功能") || title.contains("拍摄") || title.localizedCaseInsensitiveContains("button") {
            return "operation_guide_button"
        }
        return "operation_guide_touchpad"
    }

    private func localizedTitle(_ zh: String, en: String) -> String {
        if isLangZh { return zh }
        return en.isEmpty ? zh : en
    }

    /// 服务端旧数据仍可能返回「功能键」；只做展示映射，接口数据不改写。
    private func displayGuideTitle(_ guide: DeviceOperationItem) -> String {
        if isLangZh, guide.title.contains("功能键") {
            return "拍摄按钮"
        }
        if !isLangZh,
           (guide.enTitle.localizedCaseInsensitiveContains("function") || guide.title.contains("功能键")) {
            return "Camera Button"
        }
        return localizedTitle(guide.title, en: guide.enTitle)
    }

    /// 接口失败时的本地兜底（原静态页面内容）。
    private static let fallbackGuides: [DeviceOperationItem] = {
        // 用 JSON 解码构造，避免手写一堆 memberwise init。
        let json = """
        [
          {
            "id": 1,
            "pid": 0,
            "title": "拍摄按钮",
            "en_title": "Shooting Button",
            "content": "",
            "children": [
              {
                "id": 11,
                "pid": 1,
                "title": "拍摄",
                "en_title": "Capture",
                "content": "",
                "children": [
                  {"id": 111, "pid": 11, "title": "拍照", "en_title": "Take photo", "content": "短按", "en_content": "Short press"},
                  {"id": 112, "pid": 11, "title": "开始录像", "en_title": "Start recording", "content": "长按1秒", "en_content": "Long press 1s"},
                  {"id": 113, "pid": 11, "title": "结束录像", "en_title": "Stop recording", "content": "短按", "en_content": "Short press"}
                ]
              },
              {
                "id": 12,
                "pid": 1,
                "title": "系统交互",
                "en_title": "System",
                "content": "",
                "children": [
                  {"id": 121, "pid": 12, "title": "蓝牙配对", "en_title": "Bluetooth pairing", "content": "长按5秒", "en_content": "Long press 5s"},
                  {"id": 122, "pid": 12, "title": "出厂设置", "en_title": "Factory reset", "content": "短按连按5次拍摄按钮，再长按8秒拍摄按钮", "en_content": "Short press 5 times, then long press 8s"}
                ]
              }
            ]
          },
          {
            "id": 2,
            "pid": 0,
            "title": "触控板",
            "en_title": "Touchpad",
            "content": "",
            "children": [
              {
                "id": 21,
                "pid": 2,
                "title": "系统",
                "en_title": "System",
                "content": "",
                "children": [
                  {"id": 211, "pid": 21, "title": "唤起AI助手", "en_title": "AI assistant", "content": "长按", "en_content": "Long press"},
                  {"id": 212, "pid": 21, "title": "调节音量", "en_title": "Volume", "content": "前后滑动", "en_content": "Swipe"}
                ]
              },
              {
                "id": 22,
                "pid": 2,
                "title": "音乐",
                "en_title": "Music",
                "content": "",
                "children": [
                  {"id": 221, "pid": 22, "title": "播放/暂停音乐", "en_title": "Play/Pause", "content": "单击", "en_content": "Single tap"},
                  {"id": 222, "pid": 22, "title": "下一首", "en_title": "Next", "content": "双击", "en_content": "Double tap"},
                  {"id": 223, "pid": 22, "title": "上一首", "en_title": "Previous", "content": "三击", "en_content": "Triple tap"}
                ]
              },
              {
                "id": 23,
                "pid": 2,
                "title": "录音",
                "en_title": "Recording",
                "content": "",
                "children": [
                  {"id": 231, "pid": 23, "title": "开始/结束录音", "en_title": "Start/Stop recording", "content": "双指单击", "en_content": "Two-finger tap"}
                ]
              },
              {
                "id": 24,
                "pid": 2,
                "title": "通话",
                "en_title": "Call",
                "content": "",
                "children": [
                  {"id": 241, "pid": 24, "title": "接听/挂断电话", "en_title": "Answer/Hang up", "content": "双击", "en_content": "Double tap"},
                  {"id": 242, "pid": 24, "title": "拒接电话", "en_title": "Reject call", "content": "长按", "en_content": "Long press"}
                ]
              }
            ]
          }
        ]
        """
        let data = Data(json.utf8)
        return (try? JSONDecoder().decode([DeviceOperationItem].self, from: data)) ?? []
    }()
}

#Preview {
    CompatibleNavigationStack {
        OperationGuideView(modelName: "G5T71", token: nil)
    }
}
