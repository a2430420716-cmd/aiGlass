import Foundation
import UIKit

struct DeviceOTAInfo: Equatable {
    let version: String
    let downloadURL: String
    let content: String
    var isForced = false
    var englishContent = ""

    var localizedContent: String {
        L10n.usesEnglish && !englishContent.isEmpty ? englishContent : content
    }
}

private struct DeviceOTAEntry: Decodable {
    let serialNumber: String
    let version: String
    let downloadURL: String
    let content: String
    let englishContent: String
    let isForced: Bool

    enum CodingKeys: String, CodingKey {
        case version
        case content
        case englishContent = "en_content"
        case serialNumber = "serial_number"
        case downloadURL = "download_url"
        case isForced = "is_forced"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serialNumber = try container.decode(String.self, forKey: .serialNumber)
        version = try container.decode(String.self, forKey: .version)
        downloadURL = try container.decode(String.self, forKey: .downloadURL)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        englishContent = try container.decodeIfPresent(String.self, forKey: .englishContent) ?? ""
        if let value = try? container.decode(Int.self, forKey: .isForced) {
            isForced = value == 1
        } else if let value = try? container.decode(String.self, forKey: .isForced) {
            isForced = value == "1"
        } else {
            isForced = (try? container.decode(Bool.self, forKey: .isForced)) ?? false
        }
    }

    var info: DeviceOTAInfo {
        DeviceOTAInfo(version: version, downloadURL: downloadURL, content: content, isForced: isForced, englishContent: englishContent)
    }
}

struct UserInfo: Decodable {
    let id: Int
    let phone: String
    let account: String
    let nickname: String
    let headimg: String
    let openid: String
    let appInfo: AppVersionInfo?
    let device: [UserDevice]
    let firmwareBySerialNumber: [String: DeviceOTAInfo]
    let bluetoothBySerialNumber: [String: DeviceOTAInfo]

    init(
        id: Int,
        phone: String,
        account: String = "",
        nickname: String,
        headimg: String,
        openid: String = "",
        appInfo: AppVersionInfo?,
        device: [UserDevice],
        firmwareBySerialNumber: [String: DeviceOTAInfo],
        bluetoothBySerialNumber: [String: DeviceOTAInfo]
    ) {
        self.id = id
        self.phone = phone
        self.account = account
        self.nickname = nickname
        self.headimg = headimg
        self.openid = openid
        self.appInfo = appInfo
        self.device = device
        self.firmwareBySerialNumber = firmwareBySerialNumber
        self.bluetoothBySerialNumber = bluetoothBySerialNumber
    }

    func updating(nickname: String? = nil, headimg: String? = nil, devices: [UserDevice]? = nil) -> UserInfo {
        UserInfo(
            id: id,
            phone: phone,
            account: account,
            nickname: nickname ?? self.nickname,
            headimg: headimg ?? self.headimg,
            openid: openid,
            appInfo: appInfo,
            device: devices ?? device,
            firmwareBySerialNumber: firmwareBySerialNumber,
            bluetoothBySerialNumber: bluetoothBySerialNumber
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case phone
        case account
        case nickname
        case headimg
        case openid
        case device
        case appInfo = "app_info"
        case arrFirmware = "arr_firmware"
        case arrBluetooth = "arr_bluetooth"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        phone = try container.decode(String.self, forKey: .phone)
        account = try container.decodeIfPresent(String.self, forKey: .account) ?? ""
        nickname = try container.decode(String.self, forKey: .nickname)
        headimg = try container.decodeIfPresent(String.self, forKey: .headimg) ?? ""
        openid = try container.decodeIfPresent(String.self, forKey: .openid) ?? ""
        let versionInfo = try container.decodeIfPresent(AppVersionInfo.self, forKey: .appInfo)
        if let appType = versionInfo?.type, appType != 2 {
            // 忽略其他平台的更新信息，不影响用户资料和已绑定设备。
            appInfo = nil
            print("[userinfo] ignore non-iOS app_info type=\(appType)")
        } else {
            appInfo = versionInfo
        }
        device = Self.decodeDeviceList(from: container)

        let firmwareEntries = try container.decodeIfPresent([DeviceOTAEntry].self, forKey: .arrFirmware) ?? []
        var firmwareMap: [String: DeviceOTAInfo] = [:]
        for entry in firmwareEntries {
            firmwareMap[entry.serialNumber] = entry.info
        }
        firmwareBySerialNumber = firmwareMap

        let bluetoothEntries = try container.decodeIfPresent([DeviceOTAEntry].self, forKey: .arrBluetooth) ?? []
        var bluetoothMap: [String: DeviceOTAInfo] = [:]
        for entry in bluetoothEntries {
            bluetoothMap[entry.serialNumber] = entry.info
        }
        bluetoothBySerialNumber = bluetoothMap
    }

    /// 逐条解码 device，单条坏数据跳过，避免整包失败导致首页无绑定设备。
    private static func decodeDeviceList(from container: KeyedDecodingContainer<CodingKeys>) -> [UserDevice] {
        if let devices = try? container.decode([UserDevice].self, forKey: .device) {
            return devices
        }
        guard var unkeyed = try? container.nestedUnkeyedContainer(forKey: .device) else {
            return []
        }
        var parsed: [UserDevice] = []
        while !unkeyed.isAtEnd {
            if let device = try? unkeyed.decode(UserDevice.self) {
                parsed.append(device)
            } else {
                _ = try? unkeyed.decode(DiscardedJSONValue.self)
            }
        }
        if !parsed.isEmpty {
            print("[userinfo] device list partial decode count=\(parsed.count)")
        }
        return parsed
    }
}

/// 跳过无法解析的 JSON 元素。
private struct DiscardedJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(Int.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode([DiscardedJSONValue].self)) != nil { return }
        if (try? container.decode([String: DiscardedJSONValue].self)) != nil { return }
    }
}

enum MediaURLResolver {
    private static var assetBaseURLString: String { BackendRouting.rootURL.absoluteString }

    static func url(for path: String?) -> URL? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }
        let normalized = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        // 用字符串拼接，避免多段 path 被当成单一 pathComponent
        return URL(string: assetBaseURLString + normalized)
    }
}

enum AvatarImageCache {
    /// 清掉头像 URL 的 URLCache，避免同 path 覆盖后仍读旧图。
    static func purge(headimg: String?) {
        guard let url = MediaURLResolver.url(for: headimg) else { return }
        URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
        print("[AvatarCache] purged \(url.absoluteString)")
    }

    static func purge(headimgs: String?...) {
        var seen = Set<String>()
        for value in headimgs {
            guard let url = MediaURLResolver.url(for: value)?.absoluteString else { continue }
            guard seen.insert(url).inserted else { continue }
            purge(headimg: value)
        }
    }

    /// 设置成功后写入新图到 URLCache，之后进页可直接命中，不闪 placeholder。
    static func store(image: UIImage, headimg: String?) {
        guard let url = MediaURLResolver.url(for: headimg),
              let data = image.jpegData(compressionQuality: 0.9) else { return }
        let response = URLResponse(
            url: url,
            mimeType: "image/jpeg",
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        URLCache.shared.storeCachedResponse(
            CachedURLResponse(response: response, data: data),
            for: URLRequest(url: url)
        )
        print("[AvatarCache] stored \(url.absoluteString) bytes=\(data.count)")
    }

    static func cachedImage(for headimg: String?) -> UIImage? {
        guard let url = MediaURLResolver.url(for: headimg),
              let cached = URLCache.shared.cachedResponse(for: URLRequest(url: url)) else {
            return nil
        }
        return UIImage(data: cached.data)
    }
}

struct AppVersionInfo: Decodable {
    let version: String
    let downloadURL: String
    let content: String
    /// 兼容旧接口未返回类型，以及服务端返回数字字符串或空字符串。
    let type: Int?

    enum CodingKeys: String, CodingKey {
        case version
        case content
        case type
        case downloadURL = "download_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        downloadURL = try container.decode(String.self, forKey: .downloadURL)
        content = try container.decode(String.self, forKey: .content)
        if let number = try? container.decode(Int.self, forKey: .type) {
            type = number
        } else {
            let text = try? container.decode(String.self, forKey: .type)
            type = text.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}

struct UserDevice: Decodable, Identifiable, Equatable {
    let id: Int?
    /// Physical device ID used by update_device_name. `id` identifies the binding.
    let deviceID: Int?
    private(set) var deviceName: String?
    let eqName: String?
    let modelName: String?
    let deviceType: APIDeviceType?
    /// 绑定用蓝牙标识（iOS = CoreBluetooth UUID）。
    let serialNumber: String
    /// 硬件 SN（getdevinfo），接口字段可能是 sn / device_sn。
    let hardwareSN: String?
    /// 服务端连接状态。对齐 Android：非空时 `1` 表示已连接。
    let connection: String?
    let battery: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceID = "device_id"
        case battery
        case sn
        case deviceName = "device_name"
        case eqName = "eq_name"
        case modelName = "model_name"
        case deviceType = "device_type"
        case serialNumber = "serial_number"
        case deviceAddress = "device_address"
        case macAddress = "mac_address"
        case address
        case deviceSN = "device_sn"
        case connection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? container.decode(Int.self, forKey: .id) {
            id = intID
        } else if let stringID = try? container.decode(String.self, forKey: .id) {
            id = Int(stringID)
        } else {
            id = nil
        }
        deviceID = Self.decodeString(from: container, forKey: .deviceID).flatMap { Int($0) }
        deviceName = Self.decodeString(from: container, forKey: .deviceName)
        eqName = Self.decodeString(from: container, forKey: .eqName)
        modelName = Self.decodeString(from: container, forKey: .modelName)
        deviceType = try container.decodeIfPresent(APIDeviceType.self, forKey: .deviceType)
        // 对齐 Android `getUnbindSerialNumber`：云端不同设备历史数据字段不一致。
        serialNumber = [
            CodingKeys.serialNumber,
            .deviceAddress,
            .macAddress,
            .address
        ]
        .compactMap { Self.decodeString(from: container, forKey: $0) }
        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        if serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .serialNumber,
                in: container,
                debugDescription: "device identifier missing"
            )
        }

        if let snValue = Self.decodeString(from: container, forKey: .sn)
            ?? Self.decodeString(from: container, forKey: .deviceSN) {
            let trimmed = snValue.trimmingCharacters(in: .whitespacesAndNewlines)
            hardwareSN = trimmed.isEmpty ? nil : trimmed
        } else {
            hardwareSN = nil
        }

        connection = Self.decodeString(from: container, forKey: .connection)

        if let intBattery = try? container.decodeIfPresent(Int.self, forKey: .battery) {
            battery = intBattery
        } else if let stringBattery = try? container.decodeIfPresent(String.self, forKey: .battery),
                  let value = Int(stringBattery) {
            battery = value
        } else {
            battery = nil
        }
    }

    private static func decodeString(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func updatingName(_ name: String) -> UserDevice {
        var updated = self
        updated.deviceName = name
        return updated
    }

    var displayName: String {
        [deviceName, eqName, modelName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "MOCO AI Glasses"
    }

    var cardImageName: String {
        GlassDeviceModel(modelName: modelName ?? "", deviceType: deviceType).imageName
    }
}
