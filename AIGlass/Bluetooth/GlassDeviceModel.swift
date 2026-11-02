import Foundation

/// 眼镜产品型号。实际协议代际由连接后的 GATT 服务确认。
enum GlassDeviceModel: String, CaseIterable, Identifiable {
    case luminaL1 = "Lumina L1"
    case astraA1 = "Astra A1"
    case unknown = "Unknown"

    init(modelName: String) {
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if name.contains("G5K6") || name == "L1" || name.hasPrefix("L1 ")
            || name.contains("LUMINA L1") {
            self = .luminaL1
        } else if name.contains("G5T71") || name.contains("ASTRA")
            || name == "A1" || name.hasPrefix("A1 ") {
            self = .astraA1
        } else {
            self = .unknown
        }
    }

    var id: String { rawValue }

    var productLine: String { "MOCO AI Glasses" }

    var imageName: String {
        switch self {
        case .luminaL1: "glass1"
        case .astraA1, .unknown: "glass2"
        }
    }

    var connectedImageName: String {
        switch self {
        case .luminaL1: "glasses_gen1_connected"
        case .astraA1: "glasses_gen2_connected"
        case .unknown: imageName
        }
    }
}
