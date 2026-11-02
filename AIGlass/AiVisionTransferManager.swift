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
    private let gen1Assembler = Gen1ImageAssembler()
    private var gen1Timeout: DispatchWorkItem?
    private var gen1RetransmitTask: Task<Void, Never>?
    private var receiveGeneration = 0
    private var gen1TimeoutGeneration = 0
    private var gen1AwaitingRetransmission = false
    private var gen1ExpectedChunks = 0
    private var gen1ReceivedChunks = 0

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
        guard let ble, ble.isDeviceAvailable else {
            fail(L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first"))
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
        if ble.deviceGeneration == .gen1G5K61, !ble.syncAIVisionLevel(level) {
            fail(L10n.t("识图设置发送失败，请重试", "Failed to send image settings. Try again."))
            return false
        }
        let sent = ble.sendCommand(AstraA1BleProtocol.buildAIVisionCaptureCommand(level: level))
        print("\(logTag) startCapture level=\(level) sent=\(sent)")
        if ble.deviceGeneration == .gen1G5K61 {
            logGen1Vision("capture-request", detail: "level=\(level) command=0x70 sent=\(sent)")
        }
        if !sent {
            fail(L10n.t("发送识图命令失败", "Failed to send recognize command"))
            return false
        }
        if ble.deviceGeneration == .gen1G5K61 { scheduleGen1Timeout(seconds: 10) }
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
        guard ble?.isDeviceAvailable == true else {
            if isSessionActive { cancel() }
            return
        }
        if ble?.deviceGeneration == .gen1G5K61 {
            guard isSessionActive else { return }
            if command == "gen1busy0" {
                fail(L10n.t("眼镜正忙，请稍后重试", "Glasses are busy. Try again later."))
            } else if command == "gen1image0" {
                let bytes = Array(packet.prefix(8))
                if bytes.first != 2 {
                    var metadata = "packetType=\(bytes.first.map(String.init) ?? "none") payloadBytes=\(packet.count)"
                    if bytes.first == 1, bytes.count >= 4 {
                        metadata += " status=\(bytes[1]) declaredChunks=\(Int(bytes[2]) << 8 | Int(bytes[3]))"
                    } else if bytes.first == 3, bytes.count >= 8 {
                        metadata += " status=\(bytes[1]) declaredCRC=\(Int(bytes[2]) << 8 | Int(bytes[3])) declaredLength=\(Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7]))"
                    }
                    logGen1Vision("control-packet", detail: metadata)
                }
                handleGen1ImageEvent(gen1Assembler.append(packet))
            }
            return
        }
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
        // Gen1 must validate END, length and CRC; standby does not prove completion.
        guard ble?.deviceGeneration != .gen1G5K61 else { return }
        guard isSessionActive else { return }
        guard !packets.isEmpty else {
            print("\(logTag) device idle but no packets yet")
            return
        }
        finishImage(reason: "device-standby")
    }

    private func logGen1Vision(_ event: String, detail: String = "") {
        DebugLogStore.logBLEEvent("Gen1 vision \(event)", detail:
            "session=\(receiveGeneration) target=\(ble?.deviceBluetoothIdentifier ?? "none") active=\(isSessionActive) "
            + "\(gen1Assembler.diagnosticSummary) \(detail); imagePayload=omitted")
    }

    private func handleGen1ImageEvent(_ event: Gen1ImageEvent?) {
        guard isSessionActive, let event else { return }
        guard ble?.isDeviceAvailable == true else {
            cancel()
            return
        }
        switch event {
        case .started(let expected):
            logGen1Vision("started", detail: "expectedChunks=\(expected)")
            gen1RetransmitTask?.cancel()
            gen1RetransmitTask = nil
            gen1AwaitingRetransmission = false
            gen1ExpectedChunks = expected
            gen1ReceivedChunks = 0
            phase = .receiving(received: 0, total: expected)
            scheduleGen1Timeout(seconds: 10)
        case .progress(let received, let expected, _, let ack, let next):
            let advanced = received > gen1ReceivedChunks
            if ack || (advanced && (received == 1 || received % 8 == 0 || received == expected)) {
                logGen1Vision("progress", detail: "ackRequired=\(ack) nextExpected=\(next)")
            }
            gen1ReceivedChunks = received
            phase = .receiving(received: received, total: expected)
            onProgress?(received, expected)
            if ack {
                guard let payload = try? Gen1Payloads.imageChunkAck(next),
                      ble?.sendGen1Command(command: Gen1Commands.aiImage, payload: payload) == true else {
                    fail(L10n.t("图片确认发送失败，请重试", "Failed to acknowledge image data. Try again."))
                    return
                }
                logGen1Vision("window-ack-sent", detail: "nextExpected=\(next); submitted_to_BLE_is_not_device_ack")
            }
            if gen1RetransmitTask == nil, advanced || gen1Timeout == nil {
                scheduleGen1Timeout(seconds: gen1AwaitingRetransmission ? 3 : 10)
            }
        case .needRetransmit(let missing, let round, let expected, let received, _):
            logGen1Vision("retransmit-needed", detail: "round=\(round) missingCount=\(missing.count) missingPrefix=\(Array(missing.prefix(16)))")
            phase = .receiving(received: received, total: expected)
            gen1ReceivedChunks = received
            gen1AwaitingRetransmission = true
            cancelGen1Timeout()
            gen1RetransmitTask?.cancel()
            let session = receiveGeneration
            gen1RetransmitTask = Task { [weak self] in
                for offset in stride(from: 0, to: missing.count, by: 8) {
                    guard !Task.isCancelled, let self, self.isSessionActive, self.receiveGeneration == session else { return }
                    guard self.ble?.isDeviceAvailable == true else {
                        self.cancel()
                        return
                    }
                    let batch = Array(missing[offset..<min(offset + 8, missing.count)])
                    guard let payload = try? Gen1Payloads.imageRetransmitRequest(batch),
                          self.ble?.sendGen1Command(command: Gen1Commands.aiImage, payload: payload) == true else {
                        self.fail(L10n.t("图片重传请求失败，请重试", "Image retransmission request failed. Try again."))
                        return
                    }
                    self.logGen1Vision("retransmit-request-sent", detail: "sequences=\(batch)")
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                guard !Task.isCancelled, let self, self.isSessionActive, self.receiveGeneration == session else { return }
                self.gen1RetransmitTask = nil
                self.scheduleGen1Timeout(seconds: 3)
            }
        case .completed(let jpeg):
            logGen1Vision("validated", detail: "jpegBytes=\(jpeg.count) checks=length,CRC,JPEG_markers result=passed")
            // DATA-only retransmission can complete before another progress event.
            // Send the cumulative final ACK even in that case so the device can close its window.
            if let ack = try? Gen1Payloads.imageChunkAck(gen1ExpectedChunks) {
                _ = ble?.sendGen1Command(command: Gen1Commands.aiImage, payload: ack)
            }
            isSessionActive = false
            resetReceiveState()
            // Gen1 uses the same clockwise correction as its album import path.
            // Normalize once here, so chat preview and recognition upload agree.
            let correctedJPEG: Data
            do {
                correctedJPEG = try Gen1MediaOrientation.rotatePhotoClockwise90(jpeg, fileName: "vision.jpg")
                DebugLogStore.logBLEEvent("Gen1 vision image corrected", detail: "rotation=clockwise90 inputBytes=\(jpeg.count) outputBytes=\(correctedJPEG.count)")
            } catch {
                fail(L10n.t("识图照片处理失败，请重试", "Unable to process the recognition photo. Try again."))
                return
            }
            lastImageJPEG = correctedJPEG
            phase = .completed
            ble?.setAIVisionTransferBusy(false)
            onImageReceived?(correctedJPEG)
        case .error(let reason):
            logGen1Vision("validation-failed", detail: gen1Assembler.lastFailureDiagnostic ?? "reason=\(reason)")
            print("\(logTag) first-generation image failed: \(reason)")
            fail(L10n.t("图片数据校验失败，请重试", "Image data validation failed. Try again."))
        }
    }

    private func scheduleGen1Timeout(seconds: TimeInterval) {
        cancelGen1Timeout()
        let session = receiveGeneration
        let timer = gen1TimeoutGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isSessionActive, self.receiveGeneration == session,
                  self.gen1TimeoutGeneration == timer else { return }
            self.gen1Timeout = nil
            self.logGen1Vision("receive-timeout", detail: "timeoutSeconds=\(seconds) awaitingRetransmission=\(self.gen1AwaitingRetransmission)")
            if let retry = self.gen1Assembler.requestRetransmission() {
                self.handleGen1ImageEvent(retry)
            } else {
                self.fail(L10n.t("眼镜识图传输超时，请重试", "Glasses image transfer timed out. Try again."))
            }
        }
        gen1Timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelGen1Timeout() {
        gen1TimeoutGeneration += 1
        gen1Timeout?.cancel()
        gen1Timeout = nil
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
        guard ble?.isDeviceAvailable == true else {
            cancel()
            return
        }
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
        guard isSessionActive, let ble, ble.isReady, ble.deviceGeneration == .gen2 else { return }
        _ = ble.sendCommand(AstraA1BleProtocol.buildAIVisionCancelCommand())
        print("\(logTag) sent imgreccan0")
    }

    private func resetReceiveState() {
        cancelFinishIdleTimer()
        receiveGeneration += 1
        cancelGen1Timeout()
        gen1RetransmitTask?.cancel()
        gen1RetransmitTask = nil
        gen1AwaitingRetransmission = false
        gen1ExpectedChunks = 0
        gen1ReceivedChunks = 0
        gen1Assembler.reset()
        packets.removeAll(keepingCapacity: true)
        expectedJPEGLength = nil
        expectedTotalPackets = 0
        highestSeqSeen = 0
    }
}
