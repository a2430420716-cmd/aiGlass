import Combine
import Foundation

/// Lumina L1 连接状态占位。连接方式与 Astra A1 不同，后续单独实现。
enum LuminaL1ConnectionState: Equatable {
    case idle
    case unsupported
}

/// Lumina L1 连接器占位，暂未实现。
@MainActor
final class LuminaL1Connector: ObservableObject {
    @Published private(set) var connectionState: LuminaL1ConnectionState = .idle
    @Published private(set) var statusMessage = "Lumina L1 连接方式开发中"

    func startPairing() {
        connectionState = .unsupported
        statusMessage = "Lumina L1 连接方式开发中"
    }

    func cancelPairing() {
        connectionState = .idle
        statusMessage = "Lumina L1 连接方式开发中"
    }
}
