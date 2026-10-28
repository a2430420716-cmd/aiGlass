import Foundation

// Keep both production protocols unchanged in this command-line test host.
enum L10n {
    static func t(_ chinese: String, _ english: String) -> String { chinese }
}

@main
enum Gen1RuntimeStatusTests {
    private typealias Status = AstraA1BleProtocol.DeviceRuntimeStatus
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        assertions += 1
    }

    private static func canonicalStatus(_ status: UInt8) -> Status? {
        let packet = AstraA1BleProtocol.buildPacket(command: "devstatus0", payload: Data([status]))
        return AstraA1BleProtocol.parseDevStatus(packet)
    }

    private static func gen1Status(_ wireValue: UInt8) -> Status? {
        canonicalStatus(Gen1DeviceStatusMapper.toDomainStatus(wireValue).rawValue)
    }

    private static func actionResponse(_ action: UInt8, status: UInt8) -> AstraA1BleProtocol.DeviceActionResponse? {
        let packet = AstraA1BleProtocol.buildPacket(command: "actionrsp0", payload: Data([action, 0, status]))
        return AstraA1BleProtocol.parseActionResponse(packet)
    }

    private static func testGen1StatusMappings() {
        let cases: [(wire: UInt8, canonical: UInt8, expected: Status)] = [
            (0, 0, .standby),
            (1, 2, .videoRecording),
            (2, 7, .networkOperating),
            (3, 1, .photoTaking),
            (4, 8, .shuttingDown)
        ]
        for item in cases {
            check(Gen1DeviceStatusMapper.toDomainStatus(item.wire).rawValue == item.canonical,
                  "Gen1 wire \(item.wire) must emit canonical byte \(item.canonical)")
            check(gen1Status(item.wire) == item.expected,
                  "Gen1 wire \(item.wire) must survive canonical packet parsing as \(item.expected.name)")
        }

        for wire: UInt8 in [5, 6, 7, 8, 99, 0xFE, 0xFF] {
            check(Gen1DeviceStatusMapper.toDomainStatus(wire).rawValue == 0xFF,
                  "Undocumented Gen1 wire \(wire) must map to unknown, not a same-number Gen2 state")
            check(gen1Status(wire) == nil,
                  "Unknown Gen1 wire \(wire) must retain canonical parser's unknown-status rejection")
        }
    }

    private static func testActionAndStatusConsistency() {
        let cases: [(action: UInt8, canonical: UInt8, wire: UInt8, expected: AstraA1BleProtocol.DeviceAction)] = [
            (1, 1, 3, .takePhoto),
            (2, 2, 1, .startVideo),
            (3, 0, 0, .stopVideo)
        ]
        for item in cases {
            guard let response = actionResponse(item.action, status: item.canonical) else {
                preconditionFailure("Expected valid Gen1 canonical action response for \(item.action)")
            }
            check(response.action == item.expected && response.result == .accepted,
                  "Action acknowledgement must retain action identity and accepted result")
            check(response.currentStatus == gen1Status(item.wire),
                  "Action acknowledgement and subsequent Gen1 state report must agree for action \(item.action)")
        }
    }

    private static func testPhotoAndFileQuerySequence() {
        let wireSequence: [UInt8] = [3, 0, 2, 0]
        let expected: [Status] = [.photoTaking, .standby, .networkOperating, .standby]
        let actual = wireSequence.compactMap(gen1Status)
        check(actual == expected,
              "Photo completion and file query must decode as photo, standby, network, standby")
        check(!actual.contains(.videoRecording),
              "Photo/file query must never make the video button enter recording state")
        check(!actual.contains(.voiceRecording),
              "Photo status must never start an audio recording state")
    }

    private static func testVideoSequence() {
        let actual = [UInt8(1), 0].compactMap(gen1Status)
        check(actual == [.videoRecording, .standby],
              "Gen1 video start/stop reports must decode as recording then standby")
        check(!actual.contains(.photoTaking),
              "Gen1 video status must not activate photo progress")
    }

    private static func testGen2Compatibility() {
        let expected: [Status] = [
            .standby, .photoTaking, .videoRecording, .voiceRecording,
            .fileImporting, .aiVisionOperating, .firmwareUpgrading
        ]
        for (raw, status) in expected.enumerated() {
            check(canonicalStatus(UInt8(raw)) == status,
                  "Existing Gen2 runtime value \(raw) must retain \(status.name)")
        }
        check(canonicalStatus(99) == nil && canonicalStatus(0xFF) == nil,
              "Unknown canonical status values must remain rejected")
    }

    static func main() {
        testGen1StatusMappings()
        testActionAndStatusConsistency()
        testPhotoAndFileQuerySequence()
        testVideoSequence()
        testGen2Compatibility()
        let storageCases = [
            "3.6G / 16.0K": "3.6GB/16.0KB",
            "29.3G / 3.7M": "29.3GB/3.7MB",
            "3584/32768": "3.5GB/32GB",
            "12.5/512": "12.5MB/512MB",
            "3.6GB / 12.0KB": "3.6GB/12.0KB",
            "bad36data": "bad36data",
            "N/A": "—"
        ]
        for (input, expected) in storageCases {
            check(AstraA1BleProtocol.formatStorageDisplay(input) == expected,
                  "Storage units, decimal values and total/used order must survive: \(input)")
        }
        print("Gen1 runtime status tests passed: \(assertions) assertions")
    }
}
