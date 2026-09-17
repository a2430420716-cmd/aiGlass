import SwiftUI

struct DeviceSearchingSheet: View {
    let devices: [DiscoveredBLEDevice]
    let loadingText: String
    let isConnecting: Bool
    let isBinding: Bool
    let onPair: (UUID) -> Void
    let onCancel: () -> Void

    private let maxVisibleDeviceCount = 3
    private let deviceRowHeight: CGFloat = 52
    @State private var deviceListContentOffset: CGFloat = 0

    private var showsDeviceList: Bool {
        !devices.isEmpty && !isConnecting && !isBinding
    }

    private var deviceListHeight: CGFloat {
        CGFloat(min(devices.count, maxVisibleDeviceCount)) * deviceRowHeight
    }

    private var sheetHeight: CGFloat {
        if showsDeviceList {
            // 标题约 44pt，底部按钮区域 74pt；不再额外预留空白。
            return 118 + deviceListHeight
        }
        return 250
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.t("蓝牙配对请求", "Bluetooth Pairing Request"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if showsDeviceList {
                deviceList
            } else {
                loadingState
            }

            Button(action: onCancel) {
                Text(L10n.t("取消", "Cancel"))
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.cardBackground)
        .compatiblePresentationDetents([.height(sheetHeight)])
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.2)

            Text(loadingText)
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.primaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var deviceList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    HStack(spacing: 12) {
                        Text(device.displayName)
                            .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Button {
                            onPair(device.id)
                        } label: {
                            Text(L10n.t("配对", "Pair"))
                                .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: deviceRowHeight)
                    .overlay(alignment: .bottom) {
                        if index < devices.count - 1 {
                            Rectangle()
                                .fill(Color(red: 0.92, green: 0.92, blue: 0.92))
                                .frame(height: 1)
                                .padding(.leading, 20)
                        }
                    }
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DeviceListOffsetPreferenceKey.self,
                        value: proxy.frame(in: .named("device-list-scroll")).minY
                    )
                }
            }
        }
        .coordinateSpace(name: "device-list-scroll")
        .onPreferenceChange(DeviceListOffsetPreferenceKey.self) { offset in
            deviceListContentOffset = offset
        }
        .frame(height: deviceListHeight)
        .overlay(alignment: .trailing) {
            if let metrics = scrollbarMetrics {
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(Color.black.opacity(0.10))
                        .frame(width: 3, height: metrics.trackHeight)

                    Capsule()
                        .fill(Color.black.opacity(0.38))
                        .frame(width: 3, height: metrics.thumbHeight)
                        .offset(y: metrics.thumbOffset)
                }
                .padding(.vertical, 6)
                .padding(.trailing, 7)
                .allowsHitTesting(false)
            }
        }
    }

    private var scrollbarMetrics: (trackHeight: CGFloat, thumbHeight: CGFloat, thumbOffset: CGFloat)? {
        // 列表达到可视上限时即展示高度指示条；超过上限后指示块随滚动移动。
        guard devices.count >= maxVisibleDeviceCount else { return nil }
        let viewportHeight = deviceListHeight
        let contentHeight = CGFloat(devices.count) * deviceRowHeight
        let trackHeight = max(viewportHeight - 12, 1)
        let thumbHeight = max(28, trackHeight * viewportHeight / contentHeight)
        let scrollRange = max(contentHeight - viewportHeight, 1)
        let progress = min(max(-deviceListContentOffset / scrollRange, 0), 1)
        return (trackHeight, thumbHeight, progress * (trackHeight - thumbHeight))
    }
}

private struct DeviceListOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview("Searching") {
    DeviceSearchingSheet(
        devices: [],
        loadingText: L10n.t("正在搜索设备", "Searching for devices"),
        isConnecting: false,
        isBinding: false,
        onPair: { _ in },
        onCancel: {}
    )
}

#Preview("Device List") {
    DeviceSearchingSheet(
        devices: [
            DiscoveredBLEDevice(id: UUID(), displayName: "L1 0036", rssi: -50),
            DiscoveredBLEDevice(id: UUID(), displayName: "L1 0037", rssi: -60)
        ],
        loadingText: L10n.t("正在搜索设备", "Searching for devices"),
        isConnecting: false,
        isBinding: false,
        onPair: { _ in },
        onCancel: {}
    )
}
