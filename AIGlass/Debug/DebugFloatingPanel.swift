import SwiftUI
import UIKit

enum DebugPanelTab: String, CaseIterable, Identifiable {
    case connect
    case wifi
    case bluetooth
    case http

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connect: return "连接"
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "蓝牙"
        case .http: return "HTTP"
        }
    }
}

/// 独立 UIWindow：UIKit 浮球接点击；展开后全屏 SwiftUI 日志面板。
enum DebugOverlayWindow {
    private static var window: PassthroughWindow?

    static func installIfNeeded() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let win = PassthroughWindow(windowScene: scene)
        win.frame = scene.coordinateSpace.bounds
        win.windowLevel = .alert + 1
        win.backgroundColor = .clear
        win.rootViewController = UIViewController()
        win.rootViewController?.view.backgroundColor = .clear
        win.rootViewController?.view.isUserInteractionEnabled = false
        win.isHidden = false
        win.installFloatingButton()
        window = win
    }

    static var safeAreaInsets: EdgeInsets {
        let insets = window?.safeAreaInsets ?? .zero
        return EdgeInsets(
            top: insets.top,
            leading: insets.left,
            bottom: insets.bottom,
            trailing: insets.right
        )
    }

    /// 在调试浮窗所在 UIWindow 上弹出系统分享面板。
    static func presentShareSheet(items: [Any]) {
        window?.presentShareSheet(items: items)
    }
}

private final class PassthroughWindow: UIWindow {
    private let buttonSize: CGFloat = 52
    private let edgePadding: CGFloat = 12

    private lazy var floatingButton: UIButton = {
        let button = UIButton(type: .custom)
        button.frame = CGRect(x: 0, y: 0, width: buttonSize, height: buttonSize)
        button.layer.cornerRadius = buttonSize / 2
        button.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.28
        button.layer.shadowRadius = 8
        button.layer.shadowOffset = CGSize(width: 0, height: 3)
        button.setTitle("D", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        button.addTarget(self, action: #selector(openPanel), for: .touchUpInside)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        button.addGestureRecognizer(pan)
        return button
    }()

    private var panelHost: UIHostingController<DebugFullscreenPanel>?
    private var isExpanded = false
    private var panStartCenter: CGPoint = .zero

    func installFloatingButton() {
        guard floatingButton.superview == nil else { return }
        addSubview(floatingButton)
        bringSubviewToFront(floatingButton)
        // 等 layout 后再定位，避免 bounds 仍为 0。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.placeButtonDefault()
            self.bringSubviewToFront(self.floatingButton)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !isExpanded, floatingButton.superview != nil, floatingButton.center == .zero {
            placeButtonDefault()
        }
        if let panelView = panelHost?.view {
            panelView.frame = bounds
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isExpanded, let panelView = panelHost?.view {
            return panelView.hitTest(convert(point, to: panelView), with: event)
                ?? panelView
        }
        // 收起时：只有点到浮球才接事件，其余穿透。
        let pointInButton = floatingButton.convert(point, from: self)
        return floatingButton.hitTest(pointInButton, with: event)
    }

    private func placeButtonDefault() {
        let safe = safeAreaInsets
        floatingButton.center = CGPoint(
            x: bounds.width - safe.right - edgePadding - buttonSize / 2,
            y: bounds.height - safe.bottom - 120 - buttonSize / 2
        )
        clampButtonCenter()
    }

    private func clampButtonCenter() {
        let safe = safeAreaInsets
        let half = buttonSize / 2
        let minX = safe.left + edgePadding + half
        let maxX = max(minX, bounds.width - safe.right - edgePadding - half)
        let minY = safe.top + edgePadding + half
        let maxY = max(minY, bounds.height - safe.bottom - edgePadding - half)
        floatingButton.center = CGPoint(
            x: min(max(floatingButton.center.x, minX), maxX),
            y: min(max(floatingButton.center.y, minY), maxY)
        )
    }

    private func snapButtonToEdge() {
        let safe = safeAreaInsets
        let half = buttonSize / 2
        let leftX = safe.left + edgePadding + half
        let rightX = bounds.width - safe.right - edgePadding - half
        let midX = (leftX + rightX) / 2
        let x = floatingButton.center.x <= midX ? leftX : rightX
        UIView.animate(
            withDuration: 0.32,
            delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.4,
            options: [.curveEaseOut]
        ) {
            self.floatingButton.center = CGPoint(x: x, y: self.floatingButton.center.y)
            self.clampButtonCenter()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            panStartCenter = floatingButton.center
        case .changed:
            let translation = gesture.translation(in: self)
            floatingButton.center = CGPoint(
                x: panStartCenter.x + translation.x,
                y: panStartCenter.y + translation.y
            )
            clampButtonCenter()
        case .ended, .cancelled:
            snapButtonToEdge()
        default:
            break
        }
    }

    @objc private func openPanel() {
        guard !isExpanded else { return }
        isExpanded = true
        floatingButton.isHidden = true

        let panel = DebugFullscreenPanel(onClose: { [weak self] in
            self?.closePanel()
        })
        // 不走 addChild：view 直接挂 window，避免 parent VC 断言崩溃。
        let host = UIHostingController(rootView: panel)
        host.view.backgroundColor = .clear
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
        bringSubviewToFront(host.view)
        panelHost = host
    }

    private func closePanel() {
        isExpanded = false
        panelHost?.view.removeFromSuperview()
        panelHost = nil
        floatingButton.isHidden = false
        bringSubviewToFront(floatingButton)
    }

    func presentShareSheet(items: [Any]) {
        let diagnostics = SystemShareDiagnostics(items: items, source: "debugLogExport")
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.completionWithItemsHandler = { activityType, completed, returnedItems, error in
            Task { @MainActor in
                diagnostics.recordCompletion(activityType: activityType, completed: completed, returnedItems: returnedItems, error: error)
            }
        }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = CGRect(
                x: bounds.midX - 1,
                y: bounds.midY - 1,
                width: 2,
                height: 2
            )
            popover.permittedArrowDirections = []
        }

        // 面板 host 的 view 已挂在本 window 上，可直接 present。
        if let host = panelHost {
            host.present(activity, animated: true)
            return
        }

        guard let root = rootViewController else {
            diagnostics.recordDismissal()
            return
        }
        let previousInteraction = root.view.isUserInteractionEnabled
        root.view.isUserInteractionEnabled = true
        activity.completionWithItemsHandler = { activityType, completed, returnedItems, error in
            Task { @MainActor in
                diagnostics.recordCompletion(activityType: activityType, completed: completed, returnedItems: returnedItems, error: error)
                root.view.isUserInteractionEnabled = previousInteraction
            }
        }
        root.present(activity, animated: true)
    }
}

/// ContentView 空壳：触发安装。
struct DebugFloatingPanel: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                DebugOverlayWindow.installIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                DebugOverlayWindow.installIfNeeded()
            }
    }
}

/// 全屏日志面板（仅展开时挂载）。
struct DebugFullscreenPanel: View {
    var onClose: () -> Void

    @ObservedObject private var logStore = DebugLogStore.shared
    @State private var selectedTab: DebugPanelTab = .connect

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        let safe = DebugOverlayWindow.safeAreaInsets

        VStack(spacing: 0) {
            Color.clear
                .frame(height: safe.top)

            HStack(spacing: 12) {
                Text("调试")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Button(action: shareCurrentTab) {
                    Text("分析日志")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: clearCurrentTab) {
                    Text("清空")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.14))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                ForEach(DebugPanelTab.allCases) { tab in
                    Button(action: { selectedTab = tab }) {
                        Text(tabTitle(tab))
                            .font(.system(
                                size: 14,
                                weight: selectedTab == tab ? .semibold : .regular
                            ))
                            .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.55))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedTab == tab ? Color.white.opacity(0.16) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.top, 10)

            let entries = currentEntries
            if entries.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            logRow(entry)
                            Rectangle()
                                .fill(Color.white.opacity(0.18))
                                .frame(height: 1)
                                .padding(.horizontal, 12)
                        }
                    }
                    .padding(.bottom, max(safe.bottom, 12) + 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VStack(spacing: 0) {
                Color.clear.frame(height: safe.top)
                Color.black.opacity(0.92)
            }
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func logRow(_ entry: DebugLogStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.direction.label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(directionColor(entry.direction))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(directionColor(entry.direction).opacity(0.18))
                    .clipShape(Capsule())

                Text(entry.direction.peerLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                Text(Self.timeFormatter.string(from: entry.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
            }

            Text(entry.title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(entry.detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func directionColor(_ direction: DebugLogStore.Direction) -> Color {
        switch direction {
        case .sent: return .cyan
        case .received: return .orange
        case .event: return .green
        }
    }

    private var currentEntries: [DebugLogStore.Entry] {
        switch selectedTab {
        case .connect: return logStore.connectEntries
        case .wifi: return logStore.wifiEntries
        case .bluetooth: return logStore.bleEntries
        case .http: return logStore.httpEntries
        }
    }

    private var emptyHint: String {
        switch selectedTab {
        case .connect: return "暂无自动连接记录"
        case .wifi: return "暂无 Wi-Fi 连接记录"
        case .bluetooth: return "暂无蓝牙收发记录"
        case .http: return "暂无 HTTP 收发记录"
        }
    }

    private func tabTitle(_ tab: DebugPanelTab) -> String {
        let count: Int
        switch tab {
        case .connect: count = logStore.connectEntries.count
        case .wifi: count = logStore.wifiEntries.count
        case .bluetooth: count = logStore.bleEntries.count
        case .http: count = logStore.httpEntries.count
        }
        return "\(tab.title) (\(count))"
    }

    private func clearCurrentTab() {
        switch selectedTab {
        case .connect: logStore.clear(channel: .connect)
        case .wifi: logStore.clear(channel: .wifi)
        case .bluetooth: logStore.clear(channel: .ble)
        case .http: logStore.clear(channel: .http)
        }
    }

    private func shareCurrentTab() {
        let channel: DebugLogStore.Channel
        switch selectedTab {
        case .connect: channel = .connect
        case .wifi: channel = .wifi
        case .bluetooth: channel = .ble
        case .http: channel = .http
        }
        do {
            let fileURL = try logStore.exportFileURL(for: channel)
            DebugOverlayWindow.presentShareSheet(items: [fileURL])
        } catch {
            // 写文件失败时退化为直接分享纯文本。
            let text = logStore.exportText(for: channel)
            DebugOverlayWindow.presentShareSheet(items: [text])
        }
    }
}
