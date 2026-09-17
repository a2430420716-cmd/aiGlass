import Foundation

/// 眼镜型号。不同型号连接方式不同，各自独立实现。
enum GlassDeviceModel: String, CaseIterable, Identifiable {
    case luminaL1 = "Lumina L1"
    case astraA1 = "Astra A1"

    var id: String { rawValue }

    var productLine: String { "MOCO AI Glasses" }

    var imageName: String {
        switch self {
        case .luminaL1: "glass1"
        case .astraA1: "glass2"
        }
    }
}
