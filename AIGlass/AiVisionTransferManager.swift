import Combine
import Foundation
import UIKit

/// BLE 智能图像识别拼包：imgreccap0 → imgrecdata → JPEG。
/// 丢包不整图重试：收多少用多少；末包丢了也靠设备回空闲 / 静默超时收尾。
@MainActor
final class AiVisionTransferManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waitingResponse
        case receiving(received: Int, total: Int)
        case completed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastImageJPEG: Data?
    @Published private(set) var lastErrorMessage: String?

    /// 拼出的 JPEG 回调（主线程）。可能因丢包而不完整，但仍交给上层展示。
    var onImageReceived: ((Data) -> Void)?
    var onFailed: ((String) -> Void)?
    var onProgress: ((Int, Int) -> Void)?

    private weak var ble: AstraA1BleManager?

    /// 按 seq 存 payload（首包已去掉 4 字节长度头）。
    private var packets: [UInt16: Data] = [:]
    private var expectedJPEGLength: Int?
    private var expectedTotalPackets: UInt16 = 0
    private var highestSeqSeen: UInt16 = 0
    private let maxJPEGBytes = 1024 * 1024
    private var isSessionActive = false

    /// 末包丢失时：无新包一段时间后用已收数据收尾。
    private var finishIdleWorkItem: DispatchWorkItem?
    private let finishIdleSeconds: TimeInterval = 1.2

    private let logTag = "[AiVision]"

    func bind(ble: AstraA1BleManager) {
        self.ble = ble
    }

    /// 读取本地档位，发送 imgreccap0。
    @discardableResult
    func startCapture() -> Bool {
        guard let ble, ble.isReady else {
            fail(L10n.t("蓝牙未连接，无法识图", "Bluetooth not connected, cannot recognize"))
            return false
        }
        guard !ble.isBatteryTooLowForMedia else {
            fail(ble.lowBatteryMediaMessage)
            return false
        }
        if ble.deviceRuntimeStatus == .aiVisionOperating {
            fail(ble.deviceRuntimeStatus.busyMessage)
            return false
        }
        if ble.deviceRuntimeStatus != .standby, ble.deviceRuntimeStatus != .unknown {
            fail(ble.deviceRuntimeStatus.busyMessage)
            return false
        }

        resetReceiveState()
        lastImageJPEG = nil
        lastErrorMessage = nil
        isSessionActive = true
        phase = .waitingResponse
        ble.setAIVisionTransferBusy(true)

        let level = AiVisionSettings.level
        let sent = ble.sendCommand(AstraA1BleProtocol.buildAIVisionCaptureCommand(level: level))
        print("\(logTag) startCapture level=\(level) sent=\(sent)")
        if !sent {
            fail(L10n.t("发送识图命令失败", "Failed to send recognize command"))
            return false
        }
        return true
    }

    func cancel() {
        cancelFinishIdleTimer()
        sendCancelIfNeeded()
        isSessionActive = false
        resetReceiveState()
        phase = .idle
        ble?.setAIVisionTransferBusy(false)
        print("\(logTag) cancel")
    }

    /// 由 BLE notify 分发。
    func handleNotify(command: String, packet: Data) {
        guard isSessionActive || command == "imgrecrsp0" else {
            if command == "imgrecdata" {
                print("\(logTag) drop imgrecdata: session inactive")
            }
            return
        }
        switch command {
        case "imgrecrsp0":
            handleResponse(packet)
        case "imgrecdata":
            handleDataPacket(packet)
        default:
            break
        }
    }

    /// 设备 AI_VISION_OPERATING → STANDBY：末包常丢，有包就拼。
    func handleDeviceBecameIdle() {
        guard isSessionActive else { return }
        guard !packets.isEmpty else {
            print("\(logTag) device idle but no packets yet")
            return
        }
        finishImage(reason: "device-standby")
    }

    // MARK: - Private

    private func handleResponse(_ packet: Data) {
        guard let response = AstraA1BleProtocol.parseAIVisionResponse(packet) else {
            print("\(logTag) imgrecrsp0 parse failed")
            return
        }
        print("\(logTag) imgrecrsp0 op=\(response.op) status=\(response.status) err=\(response.err)")

        guard response.op == 1 else { return }

        if response.isSuccess {
            if phase == .waitingResponse {
                phase = .receiving(received: 0, total: 0)
            }
            return
        }

        fail(response.errorMessage)
    }

    private func handleDataPacket(_ packet: Data) {
        guard let parsed = AstraA1BleProtocol.parseAIVisionDataPacket(packet) else {
            print("\(logTag) imgrecdata parse failed")
            return
        }

        print("\(logTag) imgrecdata seq=\(parsed.seq)/\(parsed.total) flags=\(parsed.flags) bytes=\(parsed.payload.count)")

        // 重复包忽略。
        if packets[parsed.seq] != nil {
            print("\(logTag) drop duplicate seq=\(parsed.seq)")
            return
        }

        if parsed.isFirst {
            expectedTotalPackets = max(expectedTotalPackets, parsed.total)
            guard parsed.payload.count >= 4 else {
                print("\(logTag) first packet too short")
                return
            }
            let jpegLen = Int(parsed.payload[0])
                | (Int(parsed.payload[1]) << 8)
                | (Int(parsed.payload[2]) << 16)
                | (Int(parsed.payload[3]) << 24)
            if jpegLen > 0, jpegLen <= maxJPEGBytes {
                expectedJPEGLength = jpegLen
            } else {
                print("\(logTag) jpeg length header odd=\(jpegLen), continue best-effort")
            }
            packets[parsed.seq] = parsed.payload.subdata(in: 4..<parsed.payload.count)
        } else {
            // 首包未到也可先 stash，末包到再按 seq 拼。
            if packets.isEmpty, expectedJPEGLength == nil {
                print("\(logTag) mid packet before first, stash seq=\(parsed.seq)")
            }
            packets[parsed.seq] = parsed.payload
        }

        expectedTotalPackets = max(expectedTotalPackets, parsed.total)
        highestSeqSeen = max(highestSeqSeen, parsed.seq)

        let total = Int(max(expectedTotalPackets, 1))
        let received = packets.count
        phase = .receiving(received: received, total: total)
        onProgress?(received, total)

        // 末包到 → 用已收包拼图（缺 seq 跳过，不重试）。
        if parsed.isLast || parsed.seq == parsed.total {
            finishImage(reason: parsed.isLast ? "last-flag" : "seq==total")
            return
        }

        // 末包可能永远不来：每包后重置静默定时器，超时有多少用多少。
        scheduleFinishIdleTimer()
    }

    private func scheduleFinishIdleTimer() {
        cancelFinishIdleTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.isSessionActive, !self.packets.isEmpty else { return }
                self.finishImage(reason: "idle-timeout")
            }
        }
        finishIdleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + finishIdleSeconds, execute: work)
    }

    private func cancelFinishIdleTimer() {
        finishIdleWorkItem?.cancel()
        finishIdleWorkItem = nil
    }

    private func finishImage(reason: String) {
        guard isSessionActive else { return }
        cancelFinishIdleTimer()

        let total = max(Int(expectedTotalPackets), Int(highestSeqSeen), 1)
        var jpeg = Data()
        var missing: [UInt16] = []
        for seq in 1...UInt16(total) {
            if let chunk = packets[seq] {
                jpeg.append(chunk)
            } else {
                missing.append(seq)
            }
        }

        if !missing.isEmpty {
            print("\(logTag) finish with gaps missing=\(missing.count) e.g.\(missing.prefix(8)) reason=\(reason)")
        }

        // 有声明长度且多收了：截到声明长度（偶发重传/尾脏数据）。
        if let expected = expectedJPEGLength, jpeg.count > expected {
            print("\(logTag) trim jpeg \(jpeg.count) -> \(expected)")
            jpeg = Data(jpeg.prefix(expected))
        }

        guard !jpeg.isEmpty else {
            fail(L10n.t("未收到图片数据，请重试", "No image data received, please retry"))
            return
        }

        if jpeg.count < 2 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 {
            print("\(logTag) warn: missing JPEG SOI, still save bytes=\(jpeg.count)")
        }

        // 眼镜画面需逆时针旋 90° 再存/展示（与相册导入一致）。
        let savedJPEG: Data
        if let rotated = try? MediaOrientationFixer.rotateImageDataCounterClockwise90(
            jpeg,
            fileName: "vision.jpg"
        ) {
            savedJPEG = rotated
            print("\(logTag) rotated CCW90 \(jpeg.count) -> \(rotated.count) bytes")
        } else {
            savedJPEG = jpeg
            print("\(logTag) rotate failed, keep original bytes=\(jpeg.count)")
        }

        let got = packets.count
        isSessionActive = false
        resetReceiveState()
        lastImageJPEG = savedJPEG
        phase = .completed
        ble?.setAIVisionTransferBusy(false)
        print("\(logTag) image saved packets=\(got)/\(total) bytes=\(savedJPEG.count) missing=\(missing.count) reason=\(reason)")
        onImageReceived?(savedJPEG)
    }

    private func fail(_ message: String) {
        cancelFinishIdleTimer()
        sendCancelIfNeeded()
        isSessionActive = false
        resetReceiveState()
        lastErrorMessage = message
        phase = .failed(message)
        ble?.setAIVisionTransferBusy(false)
        print("\(logTag) failed: \(message)")
        onFailed?(message)
    }

    private func sendCancelIfNeeded() {
        guard let ble, ble.isReady else { return }
        _ = ble.sendCommand(AstraA1BleProtocol.buildAIVisionCancelCommand())
        print("\(logTag) sent imgreccan0")
    }

    private func resetReceiveState() {
        packets.removeAll(keepingCapacity: true)
        expectedJPEGLength = nil
        expectedTotalPackets = 0
        highestSeqSeen = 0
    }
}
