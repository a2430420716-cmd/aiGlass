import Foundation

struct BindDeviceRequest {
    /// 蓝牙标识：真实 MAC（Android）或 CoreBluetooth 外设 UUID（iOS）。后台「MAC地址」列对应此字段。
    let serialNumber: String
    /// 设备 SN（getdevinfo），如 G5T712604R00269。
    let sn: String
    let modelName: String
    let deviceName: String
}

struct DeviceModelItem: Decodable, Identifiable, Equatable {
    let id: Int
    let deviceType: APIDeviceType?
    let modelName: String
    let modelNameAlias: String?
    let eqName: String
    let prepare: String?
    let enPrepare: String?
    let logo: String?
    let sort: Int?
    let isWatermark: Int?
    let status: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceType = "device_type"
        case prepare
        case enPrepare = "en_prepare"
        case logo
        case sort
        case status
        case modelName = "model_name"
        case modelNameAlias = "model_name_alias"
        case eqName = "eq_name"
        case isWatermark = "is_watermark"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        deviceType = try container.decodeIfPresent(APIDeviceType.self, forKey: .deviceType)
        modelName = try container.decode(String.self, forKey: .modelName)
        modelNameAlias = try container.decodeIfPresent(String.self, forKey: .modelNameAlias)
        eqName = try container.decode(String.self, forKey: .eqName)
        prepare = try container.decodeIfPresent(String.self, forKey: .prepare)
        enPrepare = try container.decodeIfPresent(String.self, forKey: .enPrepare)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        sort = try container.decodeIfPresent(Int.self, forKey: .sort)
        isWatermark = try container.decodeIfPresent(Int.self, forKey: .isWatermark)
        status = try container.decodeIfPresent(Int.self, forKey: .status)
    }

    /// 列表展示名
    var displayName: String {
        let alias = modelNameAlias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return alias.isEmpty ? modelName : alias
    }

    /// Missing English instructions use the page's localized fallback, never Chinese HTML.
    var localizedPrepareHTML: String? {
        let html = (L10n.usesEnglish ? enPrepare : prepare)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return html?.isEmpty == false ? html : nil
    }

    var glassDeviceModel: GlassDeviceModel {
        GlassDeviceModel(modelName: modelName, deviceType: deviceType)
    }

    var fallbackImageName: String {
        glassDeviceModel.imageName
    }
}

struct DeviceGuideItem: Decodable, Identifiable, Equatable {
    let id: Int
    let modelId: Int
    let title: String
    let type: String
    let image: String
    let enTitle: String
    let enType: String

    enum CodingKeys: String, CodingKey {
        case id, title, type, image
        case modelId = "model_id"
        case enTitle = "en_title"
        case enType = "en_type"
    }

    init(
        id: Int,
        modelId: Int = 0,
        title: String,
        type: String,
        image: String = "",
        enTitle: String = "",
        enType: String = ""
    ) {
        self.id = id
        self.modelId = modelId
        self.title = title
        self.type = type
        self.image = image
        self.enTitle = enTitle
        self.enType = enType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.decodeFlexibleInt(container, forKey: .id) ?? 0
        modelId = try Self.decodeFlexibleInt(container, forKey: .modelId) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        image = try container.decodeIfPresent(String.self, forKey: .image) ?? ""
        enTitle = try container.decodeIfPresent(String.self, forKey: .enTitle) ?? ""
        enType = try container.decodeIfPresent(String.self, forKey: .enType) ?? ""
    }

    private static func decodeFlexibleInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key),
           let value = Int(text) {
            return value
        }
        return nil
    }

    /// Android `NewbieGuideActivity.defaultGuideItems` 同款兜底。
    static let newbieGuideDefaults: [DeviceGuideItem] = [
        DeviceGuideItem(
            id: 1,
            title: "单击拍摄按钮",
            type: "拍照",
            enTitle: "Click camera button",
            enType: "Take photo"
        ),
        DeviceGuideItem(
            id: 2,
            title: "长按拍摄按钮",
            type: "开始录像",
            enTitle: "Press and hold camera button",
            enType: "Start recording"
        ),
        DeviceGuideItem(
            id: 3,
            title: "单击拍摄按钮",
            type: "停止录像",
            enTitle: "Click camera button",
            enType: "Stop recording"
        ),
        DeviceGuideItem(
            id: 4,
            title: "单击触控板",
            type: "播放音乐",
            enTitle: "Tap touchpad",
            enType: "Play music"
        ),
        DeviceGuideItem(
            id: 5,
            title: "滑动一次触控板",
            type: "调节音量大小",
            enTitle: "Swipe the touchpad",
            enType: "Adjust volume"
        ),
        DeviceGuideItem(
            id: 6,
            title: "双击触控板",
            type: "播放下一首",
            enTitle: "Double tap touchpad",
            enType: "Next track"
        ),
        DeviceGuideItem(
            id: 7,
            title: "三击触控板",
            type: "播放上一首",
            enTitle: "Triple tap touchpad",
            enType: "Previous track"
        ),
        DeviceGuideItem(
            id: 8,
            title: "单击触控板",
            type: "暂停音乐",
            enTitle: "Tap touchpad",
            enType: "Pause music"
        ),
        DeviceGuideItem(
            id: 9,
            title: "长按触控板",
            type: "唤起语音助手",
            enTitle: "Press and hold touchpad",
            enType: "Voice assistant"
        )
    ]
}

/// 操作指南三级树（`device/get_device_operation`）。
struct DeviceOperationItem: Decodable, Identifiable, Equatable {
    let id: Int
    let pid: Int
    let title: String
    let enTitle: String
    let content: String
    let children: [DeviceOperationSection]

    enum CodingKeys: String, CodingKey {
        case id, pid, title, content, children
        case enTitle = "en_title"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.decodeFlexibleInt(container, forKey: .id) ?? 0
        pid = try Self.decodeFlexibleInt(container, forKey: .pid) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        enTitle = try container.decodeIfPresent(String.self, forKey: .enTitle) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        children = try container.decodeIfPresent([DeviceOperationSection].self, forKey: .children) ?? []
    }

    private static func decodeFlexibleInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let text = try? container.decodeIfPresent(String.self, forKey: key), let value = Int(text) {
            return value
        }
        return nil
    }
}

struct DeviceOperationSection: Decodable, Identifiable, Equatable {
    let id: Int
    let pid: Int
    let title: String
    let enTitle: String
    let content: String
    let children: [DeviceOperationDetail]

    enum CodingKeys: String, CodingKey {
        case id, pid, title, content, children
        case enTitle = "en_title"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.decodeFlexibleInt(container, forKey: .id) ?? 0
        pid = try Self.decodeFlexibleInt(container, forKey: .pid) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        enTitle = try container.decodeIfPresent(String.self, forKey: .enTitle) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        children = try container.decodeIfPresent([DeviceOperationDetail].self, forKey: .children) ?? []
    }

    private static func decodeFlexibleInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let text = try? container.decodeIfPresent(String.self, forKey: key), let value = Int(text) {
            return value
        }
        return nil
    }
}

struct DeviceOperationDetail: Decodable, Identifiable, Equatable {
    let id: Int
    let pid: Int
    let title: String
    let enTitle: String
    let content: String
    let enContent: String

    enum CodingKeys: String, CodingKey {
        case id, pid, title, content
        case enTitle = "en_title"
        case enContent = "en_content"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.decodeFlexibleInt(container, forKey: .id) ?? 0
        pid = try Self.decodeFlexibleInt(container, forKey: .pid) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        enTitle = try container.decodeIfPresent(String.self, forKey: .enTitle) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        enContent = try container.decodeIfPresent(String.self, forKey: .enContent) ?? ""
    }

    private static func decodeFlexibleInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let text = try? container.decodeIfPresent(String.self, forKey: key), let value = Int(text) {
            return value
        }
        return nil
    }
}

enum DeviceService {
    /// 获取设备型号列表。
    static func fetchDeviceModelList(token: String?) async throws -> [DeviceModelItem] {
        let data = try await APIClient.postRaw(
            path: "device/get_device_model_list",
            body: [:],
            authorization: token
        )

        // 完整返回打印（单行 + 分行，避免控制台截断）
        print("[get_device_model_list] bytes=\(data.count)")
        if let object = try? JSONSerialization.jsonObject(with: data),
           let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let compactText = String(data: compact, encoding: .utf8) {
            print("[get_device_model_list] \(compactText)")
        }
        if let text = String(data: data, encoding: .utf8) {
            print("[get_device_model_list] ----- begin -----")
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                print("[get_device_model_list] \(line)")
            }
            print("[get_device_model_list] ----- end -----")
        }

        let response = try JSONDecoder().decode(APIResponse<[DeviceModelItem]>.self, from: data)
        guard response.code == 0 else {
            throw APIError.server(
                message: response.msg?.isEmpty == false ? response.msg! : L10n.t("请求失败", "Request failed"),
                code: response.code
            )
        }

        let models = response.result ?? []
        // 单独打印每个型号的 prepare（必须带前缀，否则以 < 开头的行在 Xcode 控制台可能不显示）
        for model in models {
            let html = model.prepare ?? "<nil>"
            print("[get_device_model_list] prepare model_name=\(model.modelName) eq_name=\(model.eqName) length=\(model.prepare?.count ?? 0)")
            print("[get_device_model_list] prepare_html=\(html)")
        }

        return models
    }

    /// 获取设备引导信息，并打印完整返回（调试用）。
    @discardableResult
    static func fetchDeviceGuide(modelName: String, token: String?) async throws -> [DeviceGuideItem] {
        let path = "device/get_device_guide"
        let body: [String: Any] = ["model_name": modelName]
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = URL(string: trimmedPath, relativeTo: APIClient.baseURL)?.absoluteURL

        print("[get_device_guide] POST \(url?.absoluteString ?? path)")
        print("[get_device_guide] request body={\"model_name\":\"\(modelName)\"}")

        let data = try await APIClient.postRaw(
            path: path,
            body: body,
            authorization: token
        )

        print("[get_device_guide] model_name=\(modelName) bytes=\(data.count)")

        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let prettyText = String(data: pretty, encoding: .utf8) {
            print("[get_device_guide] response json:")
            for line in prettyText.split(separator: "\n", omittingEmptySubsequences: false) {
                print("[get_device_guide] \(line)")
            }
        } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            print("[get_device_guide] response text:")
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                print("[get_device_guide] \(line)")
            }
        } else {
            print("[get_device_guide] response empty")
        }

        let response = try JSONDecoder().decode(APIResponse<[DeviceGuideItem]>.self, from: data)
        guard response.code == 0 else {
            throw APIError.server(
                message: response.msg?.isEmpty == false ? response.msg! : L10n.t("请求失败", "Request failed"),
                code: response.code
            )
        }

        return response.result ?? []
    }

    /// 获取操作指南树（拍摄按钮 / 触控板等）。
    static func fetchDeviceOperation(
        modelName: String,
        token: String?
    ) async throws -> [DeviceOperationItem] {
        let path = "device/get_device_operation"
        let body: [String: Any] = ["model_name": modelName]

        print("[get_device_operation] request model_name=\(modelName)")

        let data = try await APIClient.postRaw(
            path: path,
            body: body,
            authorization: token
        )

        print("[get_device_operation] model_name=\(modelName) bytes=\(data.count)")
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
           ),
           let prettyText = String(data: pretty, encoding: .utf8) {
            for line in prettyText.split(separator: "\n", omittingEmptySubsequences: false) {
                print("[get_device_operation] \(line)")
            }
        }

        let response = try JSONDecoder().decode(APIResponse<[DeviceOperationItem]>.self, from: data)
        guard response.code == 0 else {
            throw APIError.server(
                message: response.msg?.isEmpty == false ? response.msg! : L10n.t("请求失败", "Request failed"),
                code: response.code
            )
        }
        return response.result ?? []
    }

    /// 获取单个设备型号信息。列表里的 prepare 为空时，用此接口刷新动态配对说明。
    static func fetchDeviceModel(modelName: String, token: String?) async throws -> DeviceModelItem? {
        let path = "device/get_device_model"
        let body: [String: Any] = ["model_name": modelName]
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = URL(string: trimmedPath, relativeTo: APIClient.baseURL)?.absoluteURL

        print("[get_device_model] POST \(url?.absoluteString ?? path)")
        print("[get_device_model] request body={\"model_name\":\"\(modelName)\"}")

        let data = try await APIClient.postRaw(
            path: path,
            body: body,
            authorization: token
        )

        print("[get_device_model] model_name=\(modelName) bytes=\(data.count)")

        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let prettyText = String(data: pretty, encoding: .utf8) {
            print("[get_device_model] response json:")
            for line in prettyText.split(separator: "\n", omittingEmptySubsequences: false) {
                print("[get_device_model] \(line)")
            }
        }

        if let response = try? JSONDecoder().decode(APIResponse<DeviceModelItem>.self, from: data) {
            guard response.code == 0 else {
                throw APIError.server(
                    message: response.msg?.isEmpty == false ? response.msg! : L10n.t("请求失败", "Request failed"),
                    code: response.code
                )
            }
            return response.result
        }

        // 兼容少数后端版本把单型号 result 包成数组。
        let response = try JSONDecoder().decode(APIResponse<[DeviceModelItem]>.self, from: data)
        guard response.code == 0 else {
            throw APIError.server(
                message: response.msg?.isEmpty == false ? response.msg! : L10n.t("请求失败", "Request failed"),
                code: response.code
            )
        }
        return response.result?.first
    }

    /// 绑定设备
    static func bindDevice(_ request: BindDeviceRequest, token: String) async throws {
        let body: [String: Any] = [
            "serial_number": request.serialNumber,
            "sn": request.sn,
            "model_name": request.modelName,
            "device_name": request.deviceName,
            "client_info": ClientInfo.current
        ]
        print("[Device] bind_device body=\(body)")
        _ = try await APIClient.post(
            path: "device/bind_device",
            body: body,
            authorization: token,
            as: EmptyResult.self
        )
    }

    /// Same form contract as Android. `id` is the physical device_id, not the binding id.
    static func updateDeviceName(deviceID: Int, name: String, token: String) async throws {
        guard let url = URL(string: "device/update_device_name", relativeTo: APIClient.baseURL)?.absoluteURL else {
            throw APIError.invalidURL
        }
        _ = try await APIClient.postForm(
            url: url,
            body: ["id": String(deviceID), "device_name": name],
            authorization: token,
            as: EmptyResult.self
        )
    }

    /// 解绑设备。
    /// - Parameters:
    ///   - serialNumber: 蓝牙标识（iOS = CoreBluetooth UUID），对应 `serial_number`
    ///   - sn: 设备硬件 SN（getdevinfo），对应新增 `sn` 字段
    static func unbindDevice(serialNumber: String, sn: String, token: String) async throws {
        let body: [String: Any] = [
            "serial_number": serialNumber,
            "sn": sn
        ]
        print("[Device] unbind_device body=\(body)")
        _ = try await APIClient.post(
            path: "user/unbind_device",
            body: body,
            authorization: token,
            as: EmptyResult.self
        )
    }
}
