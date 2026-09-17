import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

/// 读写 iOS 系统音量（媒体音量）。
/// - 读 / 跟实体键 / 眼镜触控板 Absolute Volume：只信系统当前音量
/// - 写：仅用户拖动 App 内滑条时，通过隐藏 `MPVolumeView` 设置
/// 全局单例：首页切走再回来、触控板调音量时 KVO 仍活着。
@MainActor
final class SystemVolumeController: ObservableObject {
    static let shared = SystemVolumeController()

    @Published private(set) var volume: Double = 0

    private var volumeObservation: NSKeyValueObservation?
    private var isSettingVolume = false
    private var isUserDragging = false
    private var requestedVolume: Double?
    /// 用户连续手势值对应的 iOS 离散系统档位。系统档位未变化时保留手势位置，避免松手回弹；
    /// 实体键/触控板改变档位后清除此基线并同步新值。
    private var displayedUserVolumeSystemBaseline: Double?
    private var volumeConfirmationWorkItem: DispatchWorkItem?
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private let volumeView = MPVolumeView(frame: .zero)
    private weak var systemSlider: UISlider?
    private weak var observedSystemSlider: UISlider?
    private var systemSliderObservation: NSKeyValueObservation?
    private var becomeActiveObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var pollDemandCount = 0
    /// 断开眼镜后冻结最后一次音量。iOS 会按输出路由保存音量，A2DP 切走时
    /// `outputVolume` 可能瞬间变成手机扬声器的 0，不能把它当成用户调节。
    private var isGlassesConnected = false

    /// 对齐 Android：眼镜 BLE 已连接即可读写当前系统媒体音量。
    /// iOS 虽按输出路由分别保存音量，但路由是否已切到 A2DP 不能阻断首页滑杆。
    private var isSystemVolumeSyncEnabled: Bool { isGlassesConnected }
    private let systemVolumeConfirmationTolerance = 0.04
    private let systemVolumeChangeEpsilon = 0.001

    private init() {
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        // MPVolumeView 必须真实位于可见 window 层级；完全透明、禁用交互或整体移出屏幕时，
        // 部分 iOS 版本只会改内部 UISlider，不会把值提交给系统。
        volumeView.alpha = 0.02
        volumeView.isUserInteractionEnabled = true
        volumeView.isHidden = false

        configureAudioSession()
        observeOutputVolume()
        volume = min(max(Double(AVAudioSession.sharedInstance().outputVolume), 0), 1)

        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWillResignActive()
            }
        }
        // 触控板经 A2DP Absolute Volume 改系统音量时，偶发只发 routeChange。
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAudioRouteChange()
            }
        }
    }

    /// 页面出现 / 回前台：读系统音量刷新 UI（含延迟重读，规避 session 短暂旧值）。
    func refresh() {
        configureAudioSession()
        observeOutputVolume()
        if isSystemVolumeSyncEnabled {
            attachVolumeViewIfNeeded()
        }
        scheduleSystemReads()
    }

    /// 首页可见期间轻量轮询：部分机型触控板调音量不触发 outputVolume KVO。
    func beginPollingWhileVisible() {
        pollDemandCount += 1
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                self?.applyReadFromSystem()
            }
        }
    }

    func endPollingWhileVisible() {
        pollDemandCount = max(0, pollDemandCount - 1)
        guard pollDemandCount == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    /// 连接时恢复读取系统音量；断连时保留当前显示值，并终止所有延迟写入。
    func setGlassesConnected(_ connected: Bool) {
        let changed = isGlassesConnected != connected
        isGlassesConnected = connected
        guard changed else { return }

        if connected {
            // 对齐 Android：BLE connected 后立刻同步当前系统媒体音量。
            displayedUserVolumeSystemBaseline = nil
            attachVolumeViewIfNeeded()
            refresh()
            return
        }

        refreshTask?.cancel()
        refreshTask = nil
        volumeConfirmationWorkItem?.cancel()
        volumeConfirmationWorkItem = nil
        requestedVolume = nil
        displayedUserVolumeSystemBaseline = nil
        isUserDragging = false
        isSettingVolume = false
        print("[SystemVolume] glasses disconnected; preserve UI volume=\(String(format: "%.3f", volume))")
    }

    /// 用户拖动 App 滑条时调用，才会改系统音量。
    func setVolume(_ value: Double) {
        guard isGlassesConnected else { return }
        let clamped = min(max(value, 0), 1)
        volume = clamped
        requestedVolume = clamped
        displayedUserVolumeSystemBaseline = nil

        isSettingVolume = true
        applySystemVolume(Float(clamped))

        // 非拖动调用仍需等待系统确认；拖动期间由结束事件统一确认。
        if !isUserDragging {
            scheduleVolumeConfirmation(expected: clamped)
        }
    }

    /// 拖动期间禁止 KVO / 轮询用旧系统值覆盖本地手势值。
    func setUserDragging(_ dragging: Bool) {
        guard isGlassesConnected else { return }
        isUserDragging = dragging
        volumeConfirmationWorkItem?.cancel()
        volumeConfirmationWorkItem = nil

        if dragging {
            isSettingVolume = true
            return
        }

        let expected = requestedVolume ?? volume
        requestedVolume = expected

        isSettingVolume = true
        applySystemVolume(Float(expected))
        scheduleVolumeConfirmation(expected: expected)
    }

    /// 对齐 Android：写系统媒体音量后，以系统实际值确认。系统尚未接收时短暂重试，
    /// 最终才解除 UI 保护，避免滑条先显示目标值、随后被旧值拉回。
    private func scheduleVolumeConfirmation(expected: Double, retry: Int = 0) {
        volumeConfirmationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isGlassesConnected, !self.isUserDragging else { return }
            self.volumeConfirmationWorkItem = nil

            // MPVolumeSlider 是本页实际读写的系统音量源；AVAudioSession 在部分蓝牙
            // Absolute Volume 场景会延迟，不能拿其旧值把刚写入的滑杆回滚。
            let actual = self.systemSlider.map { min(max(Double($0.value), 0), 1) }
                ?? min(max(Double(AVAudioSession.sharedInstance().outputVolume), 0), 1)
            // iOS 媒体音量存在档位量化，允许约半档误差。
            let isConfirmed = abs(actual - expected) <= self.systemVolumeConfirmationTolerance
            if !isConfirmed, retry < 3 {
                self.applySystemVolume(Float(expected))
                self.scheduleVolumeConfirmation(expected: expected, retry: retry + 1)
                return
            }

            self.requestedVolume = nil
            self.isSettingVolume = false
            if isConfirmed {
                // 保留用户松手位置；记住其对应系统离散档位。后续系统档位真正变化时再同步。
                self.displayedUserVolumeSystemBaseline = actual
            } else {
                // 多次写入仍未到目标：以系统真实值为准，避免显示虚假音量。
                self.displayedUserVolumeSystemBaseline = nil
                self.applySystemRead(actual)
            }
        }
        volumeConfirmationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func applyReadFromSystem() {
        guard isSystemVolumeSyncEnabled, !isSettingVolume, !isUserDragging else { return }
        attachVolumeViewIfNeeded()
        let value = systemSlider.map { min(max(Double($0.value), 0), 1) }
            ?? min(max(Double(AVAudioSession.sharedInstance().outputVolume), 0), 1)
        applySystemRead(value)
    }

    private func applySystemRead(_ value: Double) {
        if let baseline = displayedUserVolumeSystemBaseline {
            if abs(baseline - value) <= systemVolumeChangeEpsilon {
                return
            }
            displayedUserVolumeSystemBaseline = nil
        }
        if abs(volume - value) > systemVolumeChangeEpsilon {
            volume = value
            print("[SystemVolume] UI sync -> \(String(format: "%.3f", value))")
        }
    }

    private func configureAudioSession() {
        // 音量滑条只读系统音量，不参与路由决策：改 category 会打断正在播放的 AI 语音/音乐。
        GlassesAudioRouteController.activateForVolumeReadOnly()
    }

    private func observeOutputVolume() {
        volumeObservation?.invalidate()
        volumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume,
            options: [.new, .initial]
        ) { [weak self] session, _ in
            let newValue = min(max(Double(session.outputVolume), 0), 1)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isSystemVolumeSyncEnabled else { return }
                guard !self.isSettingVolume, !self.isUserDragging else { return }
                // 原生系统滑杆存在时只信它，避免 session 与 slider 到达顺序不同导致跳动。
                if self.systemSlider == nil {
                    self.applySystemRead(newValue)
                }
            }
        }
    }

    private func applySystemVolume(_ value: Float) {
        guard isSystemVolumeSyncEnabled else { return }
        attachVolumeViewIfNeeded()
        volumeView.layoutIfNeeded()
        if systemSlider == nil {
            systemSlider = findSystemSlider(in: volumeView)
            observeSystemSliderIfNeeded()
        }
        guard let slider = systemSlider else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.isSystemVolumeSyncEnabled else { return }
                self.attachVolumeViewIfNeeded()
                self.volumeView.layoutIfNeeded()
                self.systemSlider = self.findSystemSlider(in: self.volumeView)
                self.observeSystemSliderIfNeeded()
                self.systemSlider?.setValue(value, animated: false)
                self.systemSlider?.sendActions(for: [.valueChanged, .touchUpInside])
            }
            return
        }
        slider.setValue(value, animated: false)
        slider.sendActions(for: [.valueChanged, .touchUpInside])
    }

    /// iOS 会按输出路由分别保存音量。路由切换后读取新路由实际值，保持滑杆同步。
    private func handleAudioRouteChange() {
        guard isGlassesConnected else { return }

        // 用户刚拖完时若 A2DP 路由恰好切换，iOS 会暴露新路由保存的旧音量。
        // Android STREAM_MUSIC 不会丢掉这次操作；iOS 等新路由稳定后重写用户目标值。
        if let pendingUserVolume = requestedVolume {
            volumeConfirmationWorkItem?.cancel()
            volumeConfirmationWorkItem = nil
            displayedUserVolumeSystemBaseline = nil
            isSettingVolume = true
            refreshTask?.cancel()
            refreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self, self.isGlassesConnected else { return }
                let expected = self.requestedVolume ?? pendingUserVolume
                self.applySystemVolume(Float(expected))
                if !self.isUserDragging {
                    self.scheduleVolumeConfirmation(expected: expected)
                }
            }
            return
        }

        volumeConfirmationWorkItem?.cancel()
        volumeConfirmationWorkItem = nil
        requestedVolume = nil
        displayedUserVolumeSystemBaseline = nil
        if !isUserDragging { isSettingVolume = false }
        scheduleSystemReads()
    }

    /// 对齐 Android 的连接成功/系统音量广播同步；延迟重读用于等待 iOS 路由音量稳定。
    private func scheduleSystemReads() {
        refreshTask?.cancel()
        guard isSystemVolumeSyncEnabled else { return }

        applyReadFromSystem()
        refreshTask = Task { @MainActor [weak self] in
            for delayNs in [100_000_000, 300_000_000, 600_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled, let self, self.isSystemVolumeSyncEnabled else { return }
                self.applyReadFromSystem()
            }
        }
    }

    private func attachVolumeViewIfNeeded() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
        guard let window else { return }
        if volumeView.window !== window {
            volumeView.removeFromSuperview()
            systemSlider = nil
            window.addSubview(volumeView)
        }
        volumeView.isHidden = false
        // 保留 2pt 在 window 内，避免系统把完全离屏控件当作不可交互控件跳过；
        // 其余部分位于左侧屏幕外，且透明度极低，不影响现有 UI。
        volumeView.frame = CGRect(x: -158, y: 0, width: 160, height: 24)
        volumeView.layoutIfNeeded()
        systemSlider = findSystemSlider(in: volumeView)
        observeSystemSliderIfNeeded()
    }

    private func findSystemSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let slider = findSystemSlider(in: subview) { return slider }
        }
        return nil
    }

    private func observeSystemSliderIfNeeded() {
        guard let slider = systemSlider, observedSystemSlider !== slider else { return }
        systemSliderObservation?.invalidate()
        systemSliderObservation = nil
        observedSystemSlider?.removeTarget(
            self,
            action: #selector(systemSliderValueChanged(_:)),
            for: .valueChanged
        )
        slider.addTarget(
            self,
            action: #selector(systemSliderValueChanged(_:)),
            for: .valueChanged
        )
        observedSystemSlider = slider
        systemSliderObservation = slider.observe(\.value, options: [.new]) { [weak self] slider, _ in
            let value = min(max(Double(slider.value), 0), 1)
            DispatchQueue.main.async {
                self?.handleSystemSliderSample(value)
            }
        }
    }

    @objc private func systemSliderValueChanged(_ sender: UISlider) {
        handleSystemSliderSample(min(max(Double(sender.value), 0), 1))
    }

    private func handleSystemSliderSample(_ value: Double) {
        guard isSystemVolumeSyncEnabled, !isSettingVolume, !isUserDragging else { return }
        applySystemRead(value)
    }

    private func detachVolumeView() {
        systemSliderObservation?.invalidate()
        systemSliderObservation = nil
        observedSystemSlider?.removeTarget(
            self,
            action: #selector(systemSliderValueChanged(_:)),
            for: .valueChanged
        )
        observedSystemSlider = nil
        systemSlider = nil
        volumeView.removeFromSuperview()
    }

    private func handleWillResignActive() {
        refreshTask?.cancel()
        volumeConfirmationWorkItem?.cancel()
        volumeConfirmationWorkItem = nil
        requestedVolume = nil
        displayedUserVolumeSystemBaseline = nil
        isUserDragging = false
        isSettingVolume = false
        detachVolumeView()
    }
}

/// 把 UIKit `viewWillAppear` 桥到 SwiftUI。
struct ViewWillAppearHook: UIViewControllerRepresentable {
    var onWillAppear: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onWillAppear = onWillAppear
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.onWillAppear = onWillAppear
    }

    final class Controller: UIViewController {
        var onWillAppear: (() -> Void)?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            onWillAppear?()
        }
    }
}

extension View {
    func onViewWillAppear(_ action: @escaping () -> Void) -> some View {
        background(ViewWillAppearHook(onWillAppear: action).frame(width: 0, height: 0))
    }
}
