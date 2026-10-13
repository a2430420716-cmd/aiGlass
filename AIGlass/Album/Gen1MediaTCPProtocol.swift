import Foundation

nonisolated enum Gen1MediaTCPError: LocalizedError, Equatable, Sendable {
    case notConnected
    case operationInProgress
    case connectionClosed
    case timeout(String)
    case invalidFrame(String)
    case unexpectedCommand(UInt16)
    case invalidFileName(String)
    case invalidFileList
    case fileNotFound(String)
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .notConnected: return "眼镜数据通道未连接。"
        case .operationInProgress: return "眼镜正在传输其他文件。"
        case .connectionClosed: return "眼镜数据连接已断开，已接收的数据保留在手机。"
        case .timeout(let operation): return "眼镜\(operation)超时，已接收的数据保留在手机。"
        case .invalidFrame(let reason): return "眼镜数据格式异常：\(reason)"
        case .unexpectedCommand(let command): return String(format: "眼镜返回了非预期命令：0x%04X", command)
        case .invalidFileName(let name): return "眼镜文件名无效：\(name)"
        case .invalidFileList: return "无法读取眼镜返回的文件列表，数据格式无效。"
        case .fileNotFound(let name): return "眼镜未返回文件内容：\(name)"
        case .invalidDestination: return "眼镜文件保存地址无效。"
        }
    }
}

nonisolated enum Gen1MediaTCPCommand: UInt16, Sendable {
    case sendFile = 0x0001
    case fileList = 0x0003
    case heartbeat = 0x0006
    case transferComplete = 0x0007
}

nonisolated struct Gen1MediaTCPHeader: Equatable, Sendable {
    let command: UInt16
    let externalLength: Int
    let totalLength: Int64
    let usesLegacyRouting: Bool

    /// Includes the filename on SEND_FILE responses. It is not the file's byte count.
    var bodyLength: Int64 { totalLength - 20 }
}

/// G5K61 AP protocol: 18-byte BE header, body, fixed AF8C trailer.
/// `external_length` describes bytes already contained in the body; never add it twice.
nonisolated enum Gen1MediaTCPProtocol {
    static let headerSize = 18
    static let trailerSize = 2
    static let maxFileNameBytes = 255
    static let maxFileListBytes = 4 * 1024 * 1024
    static let maxHeartbeatBytes = 64
    static let trailer = Data([0xAF, 0x8C])
    private static let supportedExtensions = Set(["jpg", "jpeg", "png", "mp4", "mov", "avi"])

    static func request(_ command: Gen1MediaTCPCommand, payload: Data = Data()) throws -> Data {
        guard payload.count <= Int(UInt16.max) else {
            throw Gen1MediaTCPError.invalidFrame("request payload exceeds external_length")
        }
        var frame = Data([0xAF, 0x8C, 0, 1,
                          UInt8(command.rawValue >> 8), UInt8(command.rawValue & 0xFF),
                          0, 2, 0, 3, 0, 0,
                          UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        let total = UInt32(headerSize + payload.count + trailerSize)
        frame.append(contentsOf: [UInt8(total >> 24), UInt8((total >> 16) & 0xFF),
                                  UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)])
        frame.append(payload)
        frame.append(trailer)
        return frame
    }

    static func parseResponseHeader(_ data: Data) throws -> Gen1MediaTCPHeader {
        let bytes = [UInt8](data)
        guard bytes.count == headerSize else { throw Gen1MediaTCPError.invalidFrame("header must contain 18 bytes") }
        guard bytes[0] == 0xAF, bytes[1] == 0x8C else { throw Gen1MediaTCPError.invalidFrame("invalid magic") }
        func uint16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
        let version = uint16(2)
        let source = uint16(6)
        let target = uint16(8)
        // Older Android/UniApp framing left all three fields zero. Do not accept
        // partly zero or reversed IDs, which could be echoed client requests.
        let legacy = version == 0 && source == 0 && target == 0
        guard legacy || (version == 1 && source == 3 && target == 2) else {
            throw Gen1MediaTCPError.invalidFrame("invalid version/source/target")
        }
        guard uint16(10) == 0 else { throw Gen1MediaTCPError.invalidFrame("reserved field is not zero") }
        let total = Int64(bytes[14]) << 24 | Int64(bytes[15]) << 16 | Int64(bytes[16]) << 8 | Int64(bytes[17])
        guard total >= Int64(headerSize + trailerSize) else { throw Gen1MediaTCPError.invalidFrame("total_length is below 20") }
        let external = Int(uint16(12))
        if !legacy, Int64(external) > total - 20 {
            throw Gen1MediaTCPError.invalidFrame("external_length exceeds body")
        }
        return Gen1MediaTCPHeader(command: uint16(4), externalLength: external, totalLength: total, usesLegacyRouting: legacy)
    }

    static func validateTrailer(_ data: Data) throws {
        guard data == trailer else { throw Gen1MediaTCPError.invalidFrame("invalid AF8C trailer") }
    }

    static func validateFileName(_ name: String) throws -> Data {
        let bytes = Data(name.utf8)
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: " -_."))
        let lower = name.lowercased()
        guard !name.isEmpty, bytes.count <= maxFileNameBytes,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.hasPrefix("."), !name.contains(".."),
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              supportedExtensions.contains((lower as NSString).pathExtension),
              !["thumb", "thumbnail", "preview", "_small"].contains(where: lower.contains) else {
            throw Gen1MediaTCPError.invalidFileName(name)
        }
        return bytes
    }

    static func parseFileList(_ data: Data) throws -> [String] {
        guard data.count <= maxFileListBytes else { throw Gen1MediaTCPError.invalidFrame("file list exceeds size limit") }
        guard let text = String(data: data, encoding: .utf8) else { throw Gen1MediaTCPError.invalidFileList }
        // Only trailing transport terminators are tolerated. Embedded NUL/control
        // bytes remain invalid filename characters rather than silently disappearing.
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \r\n\t"))
        var seen = Set<String>()
        return cleaned.split(separator: ",").compactMap { part in
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (try? validateFileName(name)) != nil, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    static func fileLength(header: Gen1MediaTCPHeader, requestedName: Data) throws -> Int64 {
        guard header.command == Gen1MediaTCPCommand.sendFile.rawValue else {
            throw Gen1MediaTCPError.unexpectedCommand(header.command)
        }
        guard header.bodyLength > requestedName.count else {
            throw Gen1MediaTCPError.fileNotFound(String(decoding: requestedName, as: UTF8.self))
        }
        if header.usesLegacyRouting {
            // Known legacy senders used zero or the low 16 bits of total body length.
            // The authoritative body boundary remains the 32-bit total_length.
            let legacyLengths = [0, requestedName.count, Int(header.bodyLength & 0xFFFF)]
            guard legacyLengths.contains(header.externalLength) else {
                throw Gen1MediaTCPError.invalidFrame("unknown legacy external_length")
            }
        } else if header.externalLength != requestedName.count {
            throw Gen1MediaTCPError.invalidFrame("external_length does not match requested filename")
        }
        return header.bodyLength - Int64(requestedName.count)
    }
}
