import Foundation
import UIKit

struct DeviceOTAInfo: Equatable {
    let version: String
    let downloadURL: String
    let content: String
}

private struct DeviceOTAEntry: Decodable {
    let serialNumber: String
    let version: String
    let downloadURL: String
    let content: String

    enum CodingKeys: String, CodingKey {
        case version
        case content
        case serialNumber = "serial_number"
        case downloadURL = "download_url"
    }

    var info: DeviceOTAInfo {
        DeviceOTAInfo(version: version, downloadURL: downloadURL, content: content)
    }
}

struct UserInfo: Decodable {
    let id: Int
    let phone: String
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
        self.nickname = nickname
        self.headimg = headimg
        self.openid = openid
        self.appInfo = appInfo
        self.device = device
        self.firmwareBySerialNumber = firmwareBySerialNumber
        self.bluetoothBySerialNumber = bluetoothBySerialNumber
    }

    func updating(nickname: String? = nil, headimg: String? = nil) -> UserInfo {
        UserInfo(
            id: id,
            phone: phone,
            nickname: nickname ?? self.nickname,
            headimg: headimg ?? self.headimg,
            openid: openid,
            appInfo: appInfo,
            device: device,
            firmwareBySerialNumber: firmwareBySerialNumber,
            bluetoothBySerialNumber: bluetoothBySerialNumber
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case phone
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
        nickname = try container.decode(String.self, forKey: .nickname)
        headimg = try container.decodeIfPresent(String.self, forKey: .headimg) ?? ""
        openid = try container.decodeIfPresent(String.self, forKey: .openid) ?? ""
        appInfo = try container.decodeIfPresent(AppVersionInfo.self, forKey: .appInfo)
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
    private static let assetBaseURLString = "https://glasses.kaimou.net/"

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

    enum CodingKeys: String, CodingKey {
        case version
        case content
        case downloadURL = "download_url"
    }
}

struct UserDevice: Decodable, Identifiable, Equatable {
    let id: Int?
    let deviceName: String?
    let eqName: String?
    let modelName: String?
    /// 绑定用蓝牙标识（iOS = CoreBluetooth UUID）。
    let serialNumber: String
    /// 硬件 SN（getdevinfo），接口字段可能是 sn / device_sn。
    let hardwareSN: String?
    /// 服务端连接状态。对齐 Android：非空时 `1` 表示已连接。
    let connection: String?
    let battery: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case battery
        case sn
        case deviceName = "device_name"
        case eqName = "eq_name"
        case modelName = "model_name"
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
        deviceName = Self.decodeString(from: container, forKey: .deviceName)
        eqName = Self.decodeString(from: container, forKey: .eqName)
        modelName = Self.decodeString(from: container, forKey: .modelName)
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

    var displayName: String {
        if let deviceName, !deviceName.isEmpty {
            return deviceName
        }
        if let eqName, !eqName.isEmpty {
            return eqName
        }
        if let modelName, !modelName.isEmpty {
            return modelName
        }
        return serialNumber
    }

    var cardImageName: String {
        let model = (modelName ?? "").lowercased()
        if model.contains("astra") || model.contains("a1") || model.contains("mca") {
            return "glass2"
        }
        return "glass1"
    }
}
