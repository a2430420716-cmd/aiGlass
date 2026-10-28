import CoreBluetooth
import Foundation

/// Astra A1（G5T71）BLE 协议常量与组包/解包。
///
/// 真机实测（G5T71）UUID，与文档略有差异：
/// - Service:  04000400-0000-1000-8000-009078563412
/// - Notify:   05000500-0000-1000-8000-009178563412  (read | notify)
/// - Write:    06000600-0000-1000-8000-009278563412  (read | write | writeWithoutResponse)
///
/// 命令格式：[10字节命令头] + [2字节小端长度] + [载荷]
enum AstraA1BleProtocol {
    static let serviceUUID = CBUUID(string: "04000400-0000-1000-8000-009078563412")
    static let notifyCharacteristicUUID = CBUUID(string: "05000500-0000-1000-8000-009178563412")
    static let writeCharacteristicUUID = CBUUID(string: "06000600-0000-1000-8000-009278563412")
    static let preferredMTU = 512

    /// 标准 BLE 电池服务（0x180F）/ 电量特征（0x2A19，单字节 0-100）。
    /// 私有 getdevinfo 通知会被设备重启后的默认 MTU 截断，用标准电池服务读电量最可靠。
    static let batteryServiceUUID = CBUUID(string: "180F")
    static let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")
    /// Battery Level Status（0x2BED，BAS 1.1 新增）：Power State 位域含充电状态。设备可能不实现。
    static let batteryLevelStatusCharacteristicUUID = CBUUID(string: "2BED")

    /// 解析 Battery Level Status（0x2BED）中的充电状态。
    /// 结构：Flags(1) + Power State(2, LE) + 可选字段。
    /// Power State 位：bit1-2 有线外接电源, bit3-4 无线外接电源, bit5-6 充电状态(1=充电中)。
    static func parseCharging(fromLevelStatus data: Data) -> Bool? {
        guard data.count >= 3 else { return nil }
        let powerState = UInt16(data[1]) | (UInt16(data[2]) << 8)
        let wiredConnected = (powerState >> 1) & 0x03
        let wirelessConnected = (powerState >> 3) & 0x03
        let chargeState = (powerState >> 5) & 0x03
        return chargeState == 1 || wiredConnected == 1 || wirelessConnected == 1
    }

    static func buildPacket(command: String, payload: Data = Data()) -> Data {
        var packet = Data(count: 12 + payload.count)
        let header = Array(command.utf8.prefix(10))
        for (index, byte) in header.enumerated() {
            packet[index] = byte
        }
        let length = UInt16(payload.count)
        packet[10] = UInt8(length & 0xFF)
        packet[11] = UInt8((length >> 8) & 0xFF)
        if !payload.isEmpty {
            packet.replaceSubrange(12..<(12 + payload.count), with: payload)
        }
        return packet
    }

    /// getdevinfo：type0(5) + type_len(2, LE) + type_data(1)
    static func buildGetDevInfoCommand(type: DevInfoType) -> Data {
        var payload = Data("type0".utf8)
        payload.append(0x01)
        payload.append(0x00)
        payload.append(type.rawValue)
        return buildPacket(command: "getdevinfo", payload: payload)
    }

    /// hasnewfile：查询眼镜端待导入媒体文件数量（无载荷）。
    static func buildHasNewFileCommand() -> Data {
        buildPacket(command: "hasnewfile", payload: Data())
    }

    /// toopenwifi 用途：设备据此申请互斥状态后再决定是否开 Wi‑Fi。
    enum OpenWifiPurpose: UInt8 {
        /// 文件导入（相册导图）
        case fileImport = 0
        /// OTA（2800 / 6350 固件升级）
        case ota = 1
    }

    /// toopenwifi：开启眼镜 Wi-Fi 热点与 WebServer。
    /// 格式：toopenwifi(10) + 01 00(payloadLen=1) + purpose(1)。
    static func buildToOpenWifiCommand(purpose: OpenWifiPurpose) -> Data {
        buildPacket(command: "toopenwifi", payload: Data([purpose.rawValue]))
    }

    /// getdevstat：查询当前设备运行状态（空 payload）。
    static func buildGetDeviceStatusCommand() -> Data {
        buildPacket(command: "getdevstat", payload: Data())
    }

    /// takephoto0：眼镜拍照（4.4.1）。
    static func buildTakePhotoCommand() -> Data {
        buildPacket(command: "takephoto0", payload: Data())
    }

    /// startvideo：开始录像（4.4.2）。
    static func buildStartVideoCommand() -> Data {
        buildPacket(command: "startvideo", payload: Data())
    }

    /// stopvideo0：停止录像（4.4.3）。
    static func buildStopVideoCommand() -> Data {
        buildPacket(command: "stopvideo0", payload: Data())
    }

    /// recordtime：设置单次录像最大时长，4 字节小端秒数。
    static func buildRecordTimeCommand(seconds: Int) -> Data {
        let value = UInt32(clamping: max(0, seconds))
        return buildPacket(command: "recordtime", payload: Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]))
    }

    /// setvidres0/getvidres0：0=720p，1=1080p，2=2K。
    static func buildSetVideoResolutionCommand(profile: UInt8) -> Data {
        buildPacket(command: "setvidres0", payload: Data([min(profile, 2)]))
    }

    static func buildGetVideoResolutionCommand() -> Data {
        buildPacket(command: "getvidres0")
    }

    /// setweardet/getweardet：摘下休眠开关。
    static func buildSetWearDetectionCommand(enabled: Bool) -> Data {
        buildPacket(command: "setweardet", payload: Data([enabled ? 0x01 : 0x00]))
    }

    static func buildGetWearDetectionCommand() -> Data {
        buildPacket(command: "getweardet")
    }

    /// factreset0：进入设备端恢复出厂设置流程。
    static func buildFactoryResetCommand() -> Data {
        buildPacket(command: "factreset0")
    }

    /// vidresrsp0：status(1) + profile(1)。
    static func parseVideoResolutionResponse(_ data: Data) -> (status: UInt8, profile: UInt8)? {
        guard declaredPayloadLength(data) ?? 0 >= 2, data.count >= 14 else { return nil }
        return (data[12], min(data[13], 2))
    }

    /// weardetrsp：result(1) + enabled(1)。
    static func parseWearDetectionResponse(_ data: Data) -> (result: UInt8, enabled: Bool)? {
        guard declaredPayloadLength(data) ?? 0 >= 2, data.count >= 14 else { return nil }
        return (data[12], data[13] == 1)
    }

    /// testresult：testId(1) + result(1)，恢复出厂设置 testId=0x13。
    static func parseFactoryResetResponse(_ data: Data) -> (testID: UInt8, result: UInt8)? {
        guard declaredPayloadLength(data) ?? 0 >= 2, data.count >= 14 else { return nil }
        return (data[12], data[13])
    }

    // MARK: - AI 录音（airecord00 / synctime00）

    /// synctime00：对齐 Android，Unix 秒 + 本地时区偏移，4 字节小端。
    static func buildSyncTimeCommand(date: Date = Date()) -> Data {
        let unixSec = Int64(date.timeIntervalSince1970)
            + Int64(TimeZone.current.secondsFromGMT())
        let value = UInt32(bitPattern: Int32(truncatingIfNeeded: unixSec))
        var payload = Data(count: 4)
        payload[0] = UInt8(value & 0xFF)
        payload[1] = UInt8((value >> 8) & 0xFF)
        payload[2] = UInt8((value >> 16) & 0xFF)
        payload[3] = UInt8((value >> 24) & 0xFF)
        return buildPacket(command: "synctime00", payload: payload)
    }

    /// airecord00：开始/停止眼镜端 AI 录音。
    static func buildAIRecordCommand(enable: Bool) -> Data {
        buildPacket(command: "airecord00", payload: Data([enable ? 0x01 : 0x00]))
    }

    // MARK: - 音效模式（seteqmode0 / geteqmode0 / eqmodersp0）

    /// 设置 EQ 音效：0=标准，1=澎湃，2=静谧。
    static func buildSetEQModeCommand(mode: UInt8) -> Data {
        buildPacket(command: "seteqmode0", payload: Data([min(mode, 2)]))
    }

    /// 查询设备当前 EQ 音效。
    static func buildGetEQModeCommand() -> Data {
        buildPacket(command: "geteqmode0")
    }

    /// eqmodersp0：status(1) + mode(1)。
    static func parseEQModeResponse(_ data: Data) -> (status: UInt8, mode: UInt8)? {
        guard data.count >= 14 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        guard dataLength >= 2, data.count >= 12 + dataLength else { return nil }
        let mode = data[13]
        guard mode <= 2 else { return nil }
        return (data[12], mode)
    }

    // MARK: - AI 语音 / 语音唤醒

    /// 开启/关闭眼镜麦克风 AI 语音。连续模式 payload=[1,1]。
    static func buildAIVoiceCommand(enable: Bool, continuous: Bool = false) -> Data {
        let payload: Data
        if enable, continuous {
            payload = Data([0x01, 0x01])
        } else {
            payload = Data([enable ? 0x01 : 0x00])
        }
        return buildPacket(command: "aivoice000", payload: payload)
    }

    /// 设置连续对话的静默等待时长。固件仅接受 10 / 20 / 30 秒。
    static func buildSetAIVoiceListeningDurationCommand(seconds: Int) -> Data? {
        guard [10, 20, 30].contains(seconds) else { return nil }
        return buildPacket(command: "setaivsil0", payload: Data([UInt8(seconds)]))
    }

    static func buildGetAIVoiceListeningDurationCommand() -> Data {
        buildPacket(command: "getaivsil0")
    }

    static func buildSetVoiceWakeupCommand(enabled: Bool) -> Data {
        buildPacket(command: "setwakeup0", payload: Data([enabled ? 0x01 : 0x00]))
    }

    static func buildGetVoiceWakeupCommand() -> Data {
        buildPacket(command: "getwakeup0")
    }

    /// AI 回复播放完成后，通知眼镜继续监听下一轮。
    static func buildResumeAIVoiceListeningCommand() -> Data {
        buildPacket(command: "aivlisten0")
    }

    static func parseAIVoiceStatus(_ data: Data) -> UInt8? {
        guard data.count >= 13 else { return nil }
        let length = Int(data[10]) | (Int(data[11]) << 8)
        guard length >= 1, data.count >= 12 + length else { return nil }
        return data[12]
    }

    /// aivoicedat payload 内重复：[frameLen(1)][raw Opus frame]。
    static func parseAIVoiceFrames(_ data: Data) -> [Data] {
        guard data.count >= 12 else { return [] }
        let declared = Int(data[10]) | (Int(data[11]) << 8)
        let end = min(data.count, 12 + declared)
        guard end > 12 else { return [] }
        var frames: [Data] = []
        var offset = 12
        while offset < end {
            let frameLength = Int(data[offset])
            offset += 1
            guard frameLength > 0, offset + frameLength <= end else { break }
            frames.append(data.subdata(in: offset..<(offset + frameLength)))
            offset += frameLength
        }
        return frames
    }

    /// aivoicetur payload 首字节为当前对话 turn id。
    static func parseAIVoiceTurn(_ data: Data) -> UInt8? {
        parseAIVoiceStatus(data)
    }

    /// aivsilrsp0：status(1) + seconds(1)。
    static func parseAIVoiceListeningDurationResponse(
        _ data: Data
    ) -> (status: UInt8, seconds: Int)? {
        guard data.count >= 14 else { return nil }
        let length = Int(data[10]) | (Int(data[11]) << 8)
        guard length >= 2, data.count >= 12 + length else { return nil }
        let seconds = Int(data[13])
        return (data[12], [10, 20, 30].contains(seconds) ? seconds : 10)
    }

    /// wakeuprsp0：status(1) + enabled(1)。
    static func parseVoiceWakeupResponse(_ data: Data) -> (status: UInt8, enabled: Bool)? {
        guard data.count >= 14 else { return nil }
        let length = Int(data[10]) | (Int(data[11]) << 8)
        guard length >= 2, data.count >= 12 + length else { return nil }
        let enabled = data[13]
        guard enabled <= 1 else { return nil }
        return (data[12], enabled == 1)
    }

    // MARK: - 对话翻译录音（trslate000 / trslatests / trslatedat）

    static func buildTranslateRecordCommand(enable: Bool) -> Data {
        buildPacket(command: "trslate000", payload: Data([enable ? 0x01 : 0x00]))
    }

    static func parseTranslateRecordStatus(_ data: Data) -> UInt8? {
        parseAIVoiceStatus(data)
    }

    static func parseTranslateRecordFrames(_ data: Data) -> [Data] {
        parseAIVoiceFrames(data)
    }

    // MARK: - 智能图像识别（imgrec*）

    static func normalizeAIVisionLevel(_ level: UInt8) -> UInt8 {
        min(level, 3)
    }

    /// imgrecset0：同步识图质量档位（1 字节 0-3）。
    static func buildAIVisionSetLevelCommand(level: UInt8) -> Data {
        buildPacket(command: "imgrecset0", payload: Data([normalizeAIVisionLevel(level)]))
    }

    /// imgreccap0：触发一次拍照识图（必须携带 level）。
    static func buildAIVisionCaptureCommand(level: UInt8) -> Data {
        buildPacket(command: "imgreccap0", payload: Data([normalizeAIVisionLevel(level)]))
    }

    /// imgreccan0：取消识图会话。
    static func buildAIVisionCancelCommand() -> Data {
        buildPacket(command: "imgreccan0", payload: Data())
    }

    // MARK: - 新手引导（guidectrl0 / guideevt00）

    /// guidectrl0：进入/退出新手引导模式（1 字节 0/1）。
    static func buildGuideModeCommand(enable: Bool) -> Data {
        buildPacket(command: "guidectrl0", payload: Data([enable ? 0x01 : 0x00]))
    }

    /// guideevt00：payload 第 1 字节为事件类型。
    static func parseGuideEvent(_ data: Data) -> UInt8? {
        guard data.count >= 13 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        guard dataLength >= 1, data.count >= 12 + dataLength else { return nil }
        return data[12]
    }

    enum GuideEventType: UInt8 {
        case cameraClick = 0x01
        case cameraLongPress = 0x02
        case touchClick = 0x03
        case touchSwipe = 0x04
        case touchDoubleClick = 0x05
        case touchTripleClick = 0x06
        case touchLongPress = 0x07
    }

    struct AIVisionResponse {
        /// 0=set level，1=capture
        let op: UInt8
        /// 1=成功，0=失败
        let status: UInt8
        let err: UInt8

        var isSuccess: Bool { status == 1 }

        var errorMessage: String {
            switch err {
            case 2:
                return L10n.t("设备忙，请稍后重试", "Device is busy. Please try again later")
            case 3:
                return L10n.t("图片数据异常，请重试", "Image data is invalid. Please try again")
            case 4:
                return L10n.t("设备采集缓存溢出，请重试", "Device capture buffer overflowed. Please try again")
            case 5:
                return L10n.t("图片处理失败，请重试", "Image processing failed. Please try again")
            case 6:
                return L10n.t(
                    "图片过大，请降低质量档位或重试",
                    "Image is too large. Lower the quality level or try again"
                )
            case 7:
                return L10n.t(
                    "摄像头被遮挡，请移开遮挡后重试",
                    "Camera is blocked. Remove the obstruction and try again"
                )
            case 9:
                return L10n.t("识图质量档位无效", "Invalid image recognition quality level")
            default:
                return L10n.t("识图失败（错误码 \(err)）", "Image recognition failed (error code \(err))")
            }
        }
    }

    /// imgrecrsp0：op(1) + status(1) + err(1)
    static func parseAIVisionResponse(_ data: Data) -> AIVisionResponse? {
        guard data.count >= 15 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        guard dataLength >= 3, data.count >= 15 else { return nil }
        return AIVisionResponse(op: data[12], status: data[13], err: data[14])
    }

    struct AIVisionDataPacket {
        let seq: UInt16
        let total: UInt16
        let flags: UInt8
        let payload: Data

        var isFirst: Bool { (flags & 0x01) != 0 }
        var isLast: Bool { (flags & 0x02) != 0 }
    }

    /// imgrecdata：seq(2 LE)+total(2 LE)+flags(1)+dataLen(2 LE)+data
    static func parseAIVisionDataPacket(_ data: Data) -> AIVisionDataPacket? {
        guard data.count >= 19 else { return nil }
        let declared = Int(data[10]) | (Int(data[11]) << 8)
        guard declared >= 7, data.count >= 12 + declared else { return nil }

        let seq = UInt16(data[12]) | (UInt16(data[13]) << 8)
        let total = UInt16(data[14]) | (UInt16(data[15]) << 8)
        let flags = data[16]
        let dataLen = Int(data[17]) | (Int(data[18]) << 8)
        guard dataLen >= 0, data.count >= 19 + dataLen else { return nil }
        let payload = data.subdata(in: 19..<(19 + dataLen))
        return AIVisionDataPacket(seq: seq, total: total, flags: flags, payload: payload)
    }

    /// 统一运行状态：二代协议 0〜6，一代适配补充 7〜8；App 本地 UNKNOWN=255。
    enum DeviceRuntimeStatus: UInt8 {
        case standby = 0
        case photoTaking = 1
        case videoRecording = 2
        case voiceRecording = 3
        case fileImporting = 4
        case aiVisionOperating = 5
        case firmwareUpgrading = 6
        case networkOperating = 7
        case shuttingDown = 8
        case unknown = 0xFF

        var name: String {
            switch self {
            case .standby: return "STANDBY"
            case .photoTaking: return "PHOTO_TAKING"
            case .videoRecording: return "VIDEO_RECORDING"
            case .voiceRecording: return "VOICE_RECORDING"
            case .fileImporting: return "FILE_IMPORTING"
            case .aiVisionOperating: return "AI_VISION_OPERATING"
            case .firmwareUpgrading: return "FIRMWARE_UPGRADING"
            case .networkOperating: return "NETWORK_OPERATING"
            case .shuttingDown: return "SHUTTING_DOWN"
            case .unknown: return "UNKNOWN"
            }
        }

        var busyMessage: String {
            switch self {
            case .standby:
                return L10n.t("设备空闲", "Device is idle")
            case .photoTaking:
                return L10n.t(
                    "设备正在处理拍照中，请稍后再试",
                    "The device is taking a photo. Try again later."
                )
            case .videoRecording:
                return L10n.t(
                    "正在录像中，暂时无法操作",
                    "Recording in progress. Operation unavailable."
                )
            case .voiceRecording:
                return L10n.t(
                    "设备正在录音，请先停止录音",
                    "The device is recording audio. Try again later."
                )
            case .fileImporting:
                return L10n.t(
                    "设备正在导图，请稍后再试",
                    "The device is importing files. Try again later."
                )
            case .aiVisionOperating:
                return L10n.t(
                    "设备正在识图，请稍后再试",
                    "The device is recognizing an image. Try again later."
                )
            case .firmwareUpgrading:
                return L10n.t(
                    "设备正在升级，请勿执行其他操作",
                    "The device is updating firmware. Try again later."
                )
            case .networkOperating:
                return L10n.t(
                    "设备正在进行网络操作，请稍后再试",
                    "The device is performing a network operation. Try again later."
                )
            case .shuttingDown:
                return L10n.t(
                    "设备正在关机，请稍后再试",
                    "The device is shutting down. Try again later."
                )
            case .unknown:
                return L10n.t(
                    "设备状态同步中，请稍后再试",
                    "Device status is syncing. Try again later."
                )
            }
        }

        var logDescription: String {
            "\(rawValue) \(name) \(busyMessage)"
        }
    }

    /// actionrsp0 中的动作类型。
    enum DeviceAction: UInt8 {
        case takePhoto = 1
        case startVideo = 2
        case stopVideo = 3
        case startVoiceRecord = 4
        case stopVoiceRecord = 5
        case startFileImport = 6
        case startAIVision = 7
        case startFirmwareUpgrade = 8
        case cancelFirmwareUpgrade = 9
    }

    /// actionrsp0 中的结果值。
    enum DeviceActionResult: UInt8 {
        case accepted = 0
        case busy = 1
        case invalidState = 2
        case failed = 3
    }

    struct DeviceActionResponse {
        let action: DeviceAction
        let result: DeviceActionResult
        /// Preserve undocumented firmware rejection codes instead of dropping the response.
        let rawResult: UInt8
        let currentStatus: DeviceRuntimeStatus
    }

    /// 解析 devstatus0：payloadLen=1，payload=status。
    static func parseDevStatus(_ data: Data) -> DeviceRuntimeStatus? {
        guard data.count >= 13 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        // 有些固件偶发 len 字段异常，仍尽量读 payload 首字节。
        guard dataLength >= 1 || data.count >= 13 else { return nil }
        if let known = DeviceRuntimeStatus(rawValue: data[12]), known != .unknown {
            return known
        }
        // 未知或未定义的值不覆盖最近一次有效运行状态。
        return nil
    }

    /// 解析 actionrsp0：payloadLen=3，payload=action/result/current_status。
    static func parseActionResponse(_ data: Data) -> DeviceActionResponse? {
        guard data.count >= 15 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        guard dataLength >= 3, data.count >= 15 else { return nil }
        guard let action = DeviceAction(rawValue: data[12]) else { return nil }
        let rawResult = data[13]
        let result = DeviceActionResult(rawValue: rawResult) ?? .failed
        let status = DeviceRuntimeStatus(rawValue: data[14]) ?? .unknown
        return DeviceActionResponse(action: action, result: result, rawResult: rawResult, currentStatus: status)
    }

    /// getworkpat：获取 HTTP 路径。type 0x01=下载，0x02=OTA，0x03=上传，0x04=DLL。
    static func buildGetWorkPathCommand(pathType: UInt8 = 0x01) -> Data {
        buildPacket(command: "getworkpat", payload: Data([pathType]))
    }

    // MARK: - 蓝牙固件升级前置算法 DLL

    struct DeviceAlgorithmInfo: Equatable {
        let id: UInt8
        let build: UInt32
        let md5: String
        let flags: UInt8

        var fileExists: Bool { flags & 0x01 != 0 }
        var jsonValid: Bool { flags & 0x02 != 0 }
    }

    struct DLLUploadItem: Equatable {
        let id: UInt8
        let build: UInt32
        let md5: Data
        let fileName: String
    }

    struct DLLUpdateResult: Equatable {
        let status: UInt8
        let doneCount: UInt8
        let failID: UInt8
    }

    /// 查询眼镜现有算法 DLL：回包同名 getalgoinf。
    static func buildGetAlgorithmInfoCommand() -> Data {
        buildPacket(command: "getalgoinf")
    }

    /// getalgoinf payload：count(1) + N * [id(1), build(4 LE), md5(16), flags(1)]。
    static func parseAlgorithmInfoResponse(_ data: Data) -> [DeviceAlgorithmInfo]? {
        guard data.count >= 13,
              let dataLength = declaredPayloadLength(data),
              dataLength >= 1,
              data.count >= 12 + dataLength else { return nil }

        let end = 12 + dataLength
        let count = Int(data[12])
        var offset = 13
        var result: [DeviceAlgorithmInfo] = []
        result.reserveCapacity(count)

        for _ in 0..<count {
            guard offset + 22 <= end else { return nil }
            let id = data[offset]
            let build = UInt32(data[offset + 1])
                | (UInt32(data[offset + 2]) << 8)
                | (UInt32(data[offset + 3]) << 16)
                | (UInt32(data[offset + 4]) << 24)
            let md5 = data.subdata(in: (offset + 5)..<(offset + 21))
                .map { String(format: "%02x", $0) }
                .joined()
            let flags = data[offset + 21]
            result.append(DeviceAlgorithmInfo(id: id, build: build, md5: md5, flags: flags))
            offset += 22
        }
        return result
    }

    /// dllupload0 payload：count(1) + N * [id, build(4 LE), md5(16), nameLen, name]。
    static func buildDLLUploadCommand(items: [DLLUploadItem]) -> Data? {
        guard items.count <= Int(UInt8.max) else { return nil }
        var payload = Data([UInt8(items.count)])
        for item in items {
            let name = Data(item.fileName.utf8)
            guard item.md5.count == 16, name.count <= Int(UInt8.max) else { return nil }
            payload.append(item.id)
            payload.append(UInt8(item.build & 0xFF))
            payload.append(UInt8((item.build >> 8) & 0xFF))
            payload.append(UInt8((item.build >> 16) & 0xFF))
            payload.append(UInt8((item.build >> 24) & 0xFF))
            payload.append(item.md5)
            payload.append(UInt8(name.count))
            payload.append(name)
        }
        return buildPacket(command: "dllupload0", payload: payload)
    }

    static func parseDLLProgress(_ data: Data) -> Int? {
        guard data.count >= 13, (declaredPayloadLength(data) ?? 0) >= 1 else { return nil }
        return min(100, Int(data[12]))
    }

    static func parseDLLUpdateResult(_ data: Data) -> DLLUpdateResult? {
        guard data.count >= 15, (declaredPayloadLength(data) ?? 0) >= 3 else { return nil }
        return DLLUpdateResult(status: data[12], doneCount: data[13], failID: data[14])
    }

    /// transferok：传输完成确认。status 0x01=成功，0x00=失败。
    static func buildTransferOKCommand(success: Bool) -> Data {
        buildPacket(command: "transferok", payload: Data([success ? 0x01 : 0x00]))
    }

    /// closewifi：关闭 Wi-Fi 与 WebServer；最新固件要求携带 1 字节 0。
    static func buildCloseWifiCommand() -> Data {
        buildPacket(command: "closewifi", payload: Data([0x00]))
    }

    /// otacancel0：退出设备 OTA 状态；与 Android 一致，不携带载荷。
    static func buildOtaCancelCommand() -> Data {
        buildPacket(command: "otacancel0")
    }

    /// otaupload0：启动蓝牙固件 OTA。fileName 须与已上传到 fw_upload 的文件名一致。
    static func buildOtaUploadBluetoothCommand(fileName: String) -> Data {
        buildOtaUploadCommand(header: "otaupload0", fileName: fileName)
    }

    /// otaupload1：启动主固件 OTA。
    static func buildOtaUploadFirmwareCommand(fileName: String) -> Data {
        buildOtaUploadCommand(header: "otaupload1", fileName: fileName)
    }

    private static func buildOtaUploadCommand(header: String, fileName: String) -> Data {
        let safeName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "firmware.bin" : fileName
        var payload = Data([0x00])
        payload.append(contentsOf: safeName.utf8)
        payload.append(0x00)
        return buildPacket(command: header, payload: payload)
    }

    /// 解析 otaprogres：进度百分比 0-100。
    static func parseOtaProgress(_ data: Data) -> Int? {
        guard data.count >= 13 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        guard dataLength >= 1 else { return nil }
        let percent = Int(data[12])
        return min(max(percent, 0), 100)
    }

    /// deletefile：删除设备端已导入文件。
    static func buildDeleteFileCommand(fileNames: [String]) -> Data {
        var payload = Data()
        for name in fileNames {
            let nameData = Data(name.utf8)
            payload.append(0x01)
            let len = UInt16(nameData.count)
            payload.append(UInt8(len & 0xFF))
            payload.append(UInt8((len >> 8) & 0xFF))
            payload.append(nameData)
        }
        payload.append(contentsOf: "END".utf8)
        return buildPacket(command: "deletefile", payload: payload)
    }

    /// 对齐安卓 `DELETE_BATCH_MAX_DATA_SIZE`，但上限按当前写 MTU 收紧（含 END）。
    static func splitDeleteFileBatches(
        _ fileNames: [String],
        maxPayloadBytes: Int = 200
    ) -> [[String]] {
        let endMarkerBytes = 3 // "END"
        let maxEntriesBytes = max(1, maxPayloadBytes - endMarkerBytes)
        var batches: [[String]] = []
        var current: [String] = []
        var currentSize = 0
        for name in fileNames {
            let itemSize = 1 + 2 + name.utf8.count // type + len + name
            // 单文件已超上限：单独成批，由上层再决定是否截断失败。
            if !current.isEmpty, currentSize + itemSize > maxEntriesBytes {
                batches.append(current)
                current = []
                currentSize = 0
            }
            current.append(name)
            currentSize += itemSize
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    static func deleteFilePayloadByteCount(fileNames: [String]) -> Int {
        fileNames.reduce(3) { $0 + 1 + 2 + $1.utf8.count }
    }

    struct WifiConfig {
        var httpAddress: String?
        var ssid: String?
        var password: String?
    }

    /// 解析 wificonfig：连续 key(5)+len(2,LE)+value。
    /// 文档示例：ssid0 / psw00 / http0；兼容 key 末尾 0 填充。
    static func parseWifiConfig(_ data: Data) -> WifiConfig? {
        guard data.count >= 12 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        // 允许 dataLength 与实际包长不完全一致时尽量解析
        let end = min(data.count, 12 + max(dataLength, 0))
        guard end > 12 else { return nil }

        var config = WifiConfig()
        var offset = 12
        var parsedPairs: [(String, String)] = []

        while offset + 7 <= end {
            let keyData = data.subdata(in: offset..<(offset + 5))
            let keyRaw = String(bytes: keyData, encoding: .ascii) ?? ""
            let key = keyRaw.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
            let valueLen = Int(data[offset + 5]) | (Int(data[offset + 6]) << 8)
            offset += 7
            guard valueLen >= 0, offset + valueLen <= data.count else { break }
            let valueData = data.subdata(in: offset..<(offset + valueLen))
            let value = String(data: valueData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)) ?? ""
            offset += valueLen
            parsedPairs.append((key, value))

            let lower = key.lowercased()
            if lower.hasPrefix("http") {
                config.httpAddress = value
            } else if lower.hasPrefix("ssid") {
                config.ssid = value
            } else if lower.hasPrefix("psw") || lower.hasPrefix("pass") || lower.hasPrefix("pwd") {
                config.password = value
            }
        }

        print("[AstraA1BLE] wificonfig parsed pairs=\(parsedPairs)")
        return config
    }

    /// 解析 getworkpat 响应：pathType(1) + URL。
    static func parseGetWorkPathResponse(_ data: Data) -> String? {
        guard data.count >= 13 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        guard dataLength >= 1, data.count >= 12 + dataLength else { return nil }
        let urlData = data.subdata(in: 13..<(12 + dataLength))
        return String(data: urlData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析 toopenwifi / closewifi / deletefile 状态字节。
    static func parseStatusResponse(_ data: Data) -> Bool? {
        guard data.count >= 13 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        guard dataLength >= 1 else { return nil }
        return data[12] == 0x01
    }

    /// 解析 hasnewfile：has_new(1) + file_count(2, LE) + 可选 file_type(1)。
    /// file_type：0/缺省=相册媒体，1=AI 录音。
    static func parseHasNewFileResponse(_ data: Data) -> (hasNew: Bool, fileCount: Int, fileType: UInt8)? {
        guard data.count >= 15 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        guard dataLength >= 3 else { return nil }
        let hasNew = data[12] == 0x01
        let fileCount = Int(data[13]) | (Int(data[14]) << 8)
        let fileType: UInt8 = dataLength >= 4 && data.count >= 16 ? data[15] : 0
        return (hasNew, fileCount, fileType)
    }

    enum DevInfoType: UInt8 {
        case name = 0x01
        case model = 0x02
        case sn = 0x03
        case storage = 0x04
        case version2800 = 0x05
        case version6350 = 0x06
        case battery = 0x07
    }

    static func devInfoKey(for type: DevInfoType) -> String {
        switch type {
        case .name: return "name0"
        case .model: return "model"
        case .sn: return "sn000"
        case .storage: return "stor0"
        case .version2800: return "ver28"
        case .version6350: return "ver63"
        case .battery: return "batt0"
        }
    }

    static func parseCommandHeader(from data: Data) -> String? {
        guard data.count >= 10 else { return nil }
        let header = data.prefix(10)
        return String(bytes: header.filter { $0 != 0 }, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 设备端默认 MTU 下 notify 常被截断为 ~20 字节，需对比声明长度判断。
    static func isTruncatedPacket(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let declaredLen = Int(data[10]) | (Int(data[11]) << 8)
        guard declaredLen > 0 else { return false }
        return data.count < 12 + declaredLen
    }

    static func declaredPayloadLength(_ data: Data) -> Int? {
        guard data.count >= 12 else { return nil }
        return Int(data[10]) | (Int(data[11]) << 8)
    }

    static func parseGetDevInfoResponse(_ data: Data) -> (key: String, value: String, rawValue: Data)? {
        guard data.count >= 19 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        guard data.count >= 12 + dataLength, dataLength >= 7 else { return nil }

        let keyData = data.subdata(in: 12..<17)
        let key = String(bytes: keyData.filter { $0 != 0 }, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let valueLength = Int(data[17]) | (Int(data[18]) << 8)
        guard data.count >= 19 + valueLength else { return nil }
        let valueData = data.subdata(in: 19..<(19 + valueLength))
        let value = String(data: valueData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (key, value, valueData)
    }

    /// batteryntf：眼镜连上后约每 2 分钟主动上报一次，payload 首字节为 0-100 的电量百分比。
    static func parseBatteryNotify(_ data: Data) -> Int? {
        guard data.count >= 13 else { return nil }
        let dataLength = Int(data[10]) | (Int(data[11]) << 8)
        guard dataLength >= 1 else { return nil }
        return max(0, min(100, Int(data[12])))
    }

    /// 解析电量字符串，并尽量识别充电状态。
    /// 支持：纯数字 `"13"`；`"13,1"` / `"13|1"` / `"13/1"`（末位 1=充电）；
    /// 以及 value 原始字节在数字后多 1 字节且为 `0x01` 表示充电。
    static func parseBatteryValue(_ value: String, rawValue: Data) -> (percent: Int?, isCharging: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.uppercased() != "N/A" else {
            return (nil, false)
        }

        var isCharging = false
        var numberPart = trimmed

        let separators = CharacterSet(charactersIn: ",|/")
        if let range = trimmed.rangeOfCharacter(from: separators) {
            let parts = trimmed.components(separatedBy: separators).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if parts.count >= 2 {
                numberPart = parts[0]
                let flag = parts[1].lowercased()
                isCharging = (flag == "1" || flag == "true" || flag == "c" || flag == "charg")
            }
        } else {
            let lower = trimmed.lowercased()
            if lower.contains("charg") || lower.hasSuffix("+") || lower.hasSuffix("c") {
                isCharging = true
                numberPart = trimmed.filter(\.isNumber)
            }
        }

        let digits = numberPart.filter(\.isNumber)
        let percent = Int(digits)

        // 原始字节：ASCII 数字后额外 1 字节 0x01 视为充电
        if !isCharging, let percent, digits.utf8.count < rawValue.count {
            let flagIndex = rawValue.index(rawValue.startIndex, offsetBy: digits.utf8.count)
            if rawValue[flagIndex] == 0x01 {
                isCharging = true
            }
        }

        if let percent {
            return (max(0, min(100, percent)), isCharging)
        }
        return (nil, isCharging)
    }

    /// 将 stor0 返回值格式化为 UI 展示（如 `3584/32768` → `3.5GB/32GB`）。
    static func formatStorageDisplay(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.uppercased() != "N/A" else { return "—" }

        let parts = trimmed.split { $0 == "/" || $0 == "," || $0 == "|" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parts.count == 2 {
            return "\(formatStorageComponent(parts[0]))/\(formatStorageComponent(parts[1]))"
        }

        return formatStorageComponent(trimmed)
    }

    private static func formatStorageComponent(_ raw: String) -> String {
        let upper = raw.uppercased()
        // Gen1 returns text such as 3.6G / 16.0K. Never strip non-digits:
        // that changes these values into 36MB / 160MB.
        let units = ["TB", "GB", "MB", "KB", "B", "T", "G", "M", "K"]
        if let unit = units.first(where: { upper.hasSuffix($0) }) {
            let number = String(upper.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value.isFinite, value >= 0 else { return raw }
            return number + (unit.count == 1 && unit != "B" ? unit + "B" : unit)
        }
        guard let number = Double(raw), number.isFinite, number >= 0 else { return raw }
        if number >= 1024 {
            let gb = number / 1024.0
            if gb.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fGB", gb)
            }
            return String(format: "%.1fGB", gb)
        }
        return number.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fMB", number) : "\(raw)MB"
    }
}
