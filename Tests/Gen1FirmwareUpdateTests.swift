import Foundation

// swiftc -module-cache-path /tmp/aiglass-gen1-module-cache \
//   AIGlass/Gen1FirmwareUpdateProtocol.swift Tests/Gen1FirmwareUpdateTests.swift \
//   -o /tmp/aiglass-gen1-ota-tests && /tmp/aiglass-gen1-ota-tests
@main
enum Gen1FirmwareUpdateTests {
    private static var assertionCount = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String = "") {
        precondition(condition(), message)
        assertionCount += 1
    }

    private static func expectValidationError(_ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("Invalid firmware input accepted")
        } catch is Gen1FirmwareUpdateProtocol.ValidationError {
            assertionCount += 1
        } catch {
            preconditionFailure("Unexpected validation error: \(error)")
        }
    }

    static func main() throws {
        let url = "http://firmware.example.com/G5K61_v1.02.3.bin?token=abc%20def"
        let payload = try Gen1FirmwareUpdateProtocol.urlPayload(" \(url)\n")
        expect(payload.first == 1)
        expect(String(data: payload.dropFirst(), encoding: .ascii) == url)
        expect(payload.count == url.utf8.count + 1, "URL payload must not append a NUL")

        for invalid in ["https://example.com/fw.bin", "http://", "http://user:pass@example.com/fw.bin",
                        "http://example.com/固件.bin", "http://example.com/firm ware.bin",
                        "http://example.com/fw.bin#fragment", "http://example.com/" + String(repeating: "a", count: 16_384)] {
            expectValidationError {
                _ = try Gen1FirmwareUpdateProtocol.urlPayload(invalid)
            }
        }

        let trustedBase = URL(string: "https://FIRMWARE.example.com/api/")!
        let httpsURL = url.replacingOccurrences(of: "http://", with: "https://")
        let downgraded = try Gen1FirmwareUpdateProtocol.urlPayload(httpsURL, trustedBaseURL: trustedBase)
        expect(downgraded == payload, "Trusted host downgrade must preserve the exact path and query")
        let withPort = try Gen1FirmwareUpdateProtocol.urlPayload(
            "https://firmware.example.com:8080/fw.bin?q=x%2Fy", trustedBaseURL: trustedBase
        )
        expect(String(data: withPort.dropFirst(), encoding: .ascii) == "http://firmware.example.com:8080/fw.bin?q=x%2Fy")
        for invalid in ["https://other.example.com/fw.bin", "https://sub.firmware.example.com/fw.bin",
                        "https://firmware.example.com.evil.test/fw.bin",
                        "https://user:pass@firmware.example.com/fw.bin",
                        "https://firmware.example.com/fw.bin#fragment",
                        "https://firmware.example.com/固件.bin", "https://firmware.example.com/fw file.bin"] {
            expectValidationError {
                _ = try Gen1FirmwareUpdateProtocol.urlPayload(invalid, trustedBaseURL: trustedBase)
            }
        }
        let maxURL = "http://example.com/" + String(repeating: "a", count: 16_383 - "http://example.com/".utf8.count)
        let maxPayload = try Gen1FirmwareUpdateProtocol.urlPayload(maxURL)
        expect(maxPayload.count == 16_384)
        expectValidationError { _ = try Gen1FirmwareUpdateProtocol.urlPayload(maxURL + "a") }

        let credentials = Gen1FirmwareWifiCredentials(ssid: "  家庭 Wi-Fi\n", password: " pass word ")
        let wifi = try Gen1FirmwareUpdateProtocol.wifiPayload(ssid: credentials.ssid, password: credentials.password)
        expect(wifi == Data("家庭 Wi-Fi/ pass word ".utf8), "Only SSID is trimmed; password is preserved")
        let openNetwork = try Gen1FirmwareUpdateProtocol.wifiPayload(ssid: "Open", password: "")
        expect(openNetwork == Data("Open/".utf8))
        let maxASCII = String(repeating: "a", count: 127)
        let maxUTF8 = String(repeating: "网", count: 42) + "a"
        let boundaryWifi = try Gen1FirmwareUpdateProtocol.wifiPayload(ssid: maxUTF8, password: maxASCII)
        expect(boundaryWifi.count == 255)
        for ssid in ["", " \n\t", maxASCII + "a", String(repeating: "网", count: 43)] {
            expectValidationError { _ = try Gen1FirmwareUpdateProtocol.wifiPayload(ssid: ssid, password: "password") }
        }
        for password in [maxASCII + "a", String(repeating: "密", count: 43)] {
            expectValidationError { _ = try Gen1FirmwareUpdateProtocol.wifiPayload(ssid: "Wi-Fi", password: password) }
        }
        let slashPassword = try Gen1FirmwareUpdateProtocol.wifiPayload(ssid: "Wi-Fi", password: "pass/word")
        expect(slashPassword == Data("Wi-Fi/pass/word".utf8), "Password bytes follow Android without escaping")

        expect(FirmwareUpgradeBatteryPolicy.gen1MinimumPercent == 80)
        expect(FirmwareUpgradeBatteryPolicy.gen2MinimumPercent == 50)
        for minimum in [FirmwareUpgradeBatteryPolicy.gen1MinimumPercent, FirmwareUpgradeBatteryPolicy.gen2MinimumPercent] {
            for percent in 0...100 {
                expect(FirmwareUpgradeBatteryPolicy.allowsUpgrade(percent: percent, minimumPercent: minimum) == (percent >= minimum),
                       "Battery gate includes its threshold and rejects lower readings")
            }
            for percent: Int? in [nil, -1, 101, 255] {
                expect(!FirmwareUpgradeBatteryPolicy.allowsUpgrade(percent: percent, minimumPercent: minimum),
                       "Unknown or invalid battery blocks both generations")
            }
        }
        expect(!FirmwareUpgradeBatteryPolicy.allowsUpgrade(percent: 100, minimumPercent: -1), "Invalid minimum cannot bypass gate")
        expect(!FirmwareUpgradeBatteryPolicy.allowsUpgrade(percent: 100, minimumPercent: 101), "Invalid minimum cannot form a range")
        expect(Gen1FirmwareUpdateProtocol.minimumBatteryPercent == 80)
        expect(Gen1FirmwareUpdateProtocol.batteryLevel(reported: 75, baseline: 80) == 75, "Fresh low battery overrides older high cache")
        expect(Gen1FirmwareUpdateProtocol.batteryLevel(reported: 85, baseline: 80) == 85)
        expect(Gen1FirmwareUpdateProtocol.batteryLevel(reported: 75, baseline: 70) == 75)
        expect(Gen1FirmwareUpdateProtocol.batteryLevel(reported: nil, baseline: 80) == 80)
        expect(Gen1FirmwareUpdateProtocol.batteryLevel(reported: 80, baseline: nil) == 80)
        expect(Gen1FirmwareUpdateProtocol.batteryLevel(reported: 0, baseline: nil) == 0)
        expect(Gen1FirmwareUpdateProtocol.batteryLevel(reported: 100, baseline: nil) == 100)
        expect(Gen1FirmwareUpdateProtocol.batteryLevel(reported: 255, baseline: 75) == 75)
        expect(Gen1FirmwareUpdateProtocol.batteryLevel(reported: 75, baseline: -1) == 75)
        expect(Gen1FirmwareUpdateProtocol.batteryLevel(reported: nil, baseline: nil) == nil)
        expect(Gen1FirmwareUpdateProtocol.batteryLevel(reported: -1, baseline: 101) == nil)

        for command: UInt8 in [0x3A, 0x18] {
            expect(Gen1FirmwareUpdateProtocol.progress(command: command, payload: Data()) == nil)
            for value in 0...255 {
                let expected = value <= 100 ? value : nil
                expect(Gen1FirmwareUpdateProtocol.progress(command: command, payload: Data([UInt8(value)])) == expected)
            }
        }
        expect(Gen1FirmwareUpdateProtocol.progress(command: 0x09, payload: Data([100])) == nil)
        expect(Gen1FirmwareUpdateProtocol.progress(command: 0x3A, payload: Data([35, 0])) == 35)

        expect(Gen1FirmwareUpdateProtocol.versionsMatch("1.02.3", target: "1.2.3"))
        expect(Gen1FirmwareUpdateProtocol.versionsMatch("G5K61_V1.02.3_20250901", target: "V1.2.3"))
        expect(!Gen1FirmwareUpdateProtocol.versionsMatch("1.2.3", target: "1.2.4"))
        expect(!Gen1FirmwareUpdateProtocol.versionsMatch("", target: "1.2.3"))
        expect(!Gen1FirmwareUpdateProtocol.versionsMatch("unknown", target: "1.2.3"))
        print("Gen1 firmware update: \(assertionCount) assertions passed")
    }
}
