import Foundation

@main
struct Gen1APImportTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
        checks += 1
        let result = try value()
        precondition(result, message)
    }

    static func main() throws {
        try Gen1APImportProtocol.requireStandby(fresh: .standby, current: .networkOperating, lastReported: .networkOperating)
        try Gen1APImportProtocol.requireStandby(fresh: nil, current: .standby, lastReported: .standby)
        for (fresh, current, reported, expected) in [
            (Gen1DomainDeviceStatus.networkOperating, Gen1DomainDeviceStatus.standby, Gen1DomainDeviceStatus.standby, Gen1APImportError.deviceBusy),
            (.unknown, .standby, .standby, .statusUnconfirmed),
            (nil, .networkOperating, .standby, .deviceBusy),
            (nil, .unknown, .standby, .statusUnconfirmed),
            (nil, .standby, .unknown, .statusUnconfirmed)
        ] as [(Gen1DomainDeviceStatus?, Gen1DomainDeviceStatus, Gen1DomainDeviceStatus, Gen1APImportError)] {
            do {
                try Gen1APImportProtocol.requireStandby(fresh: fresh, current: current, lastReported: reported)
                preconditionFailure("Busy or unconfirmed state allowed hotspot open")
            } catch { expect(error as? Gen1APImportError == expected, "Fresh reports override cache; unconfirmed idle is rejected") }
        }
        let raw = Data([0xAA, 3, 2, 0x37, 0, 20]) + Data("Lunima_L1/L13d4f5g6h".utf8) + Data([0x72, 0x63])
        let frame = Gen1ControlCodec.parse(raw)!
        let credentials = try Gen1APImportProtocol.credentials(from: frame.payload)
        expect(frame.command == 0x37 && frame.sender == 3 && frame.receiver == 2, "Confirmed 0x37 response")
        expect(credentials == .init(ssid: "Lunima_L1", password: "L13d4f5g6h"), "Firmware credentials vector")
        let spaced = try Gen1APImportProtocol.credentials(from: Data(" ID-looking SSID /pass/word".utf8))
        expect(spaced.ssid == " ID-looking SSID " && spaced.password == "pass/word", "Preserve SSID bytes and split first slash")
        for code: UInt8 in [0, 1, 2, 3, 0x78, 0xE1, 0xE2, 0xE3, 0xFF] {
            do { _ = try Gen1APImportProtocol.credentials(from: Data([code])); preconditionFailure("Accepted failure code") }
            catch { expect(error as? Gen1APImportError == .hotspotRejected(code), "One-byte replies are AP failures, including recording-like 1/2") }
        }
        for value in ["", "SSID", "/password", "ssid/", "ssid/short", "ssid/12345678\0", "ssid/12345678\n", "中文/12345678", String(repeating: "x", count: 33) + "/12345678"] {
            do { _ = try Gen1APImportProtocol.credentials(from: Data(value.utf8)); preconditionFailure("Accepted \(value)") }
            catch { expect(error as? Gen1APImportError == .invalidCredentials, "Malformed credential rejected") }
        }
        let request = try Gen1ControlCodec.buildCommand(command: Gen1Commands.openHotspot)
        expect(request == Data([0xAA, 2, 3, 0x37, 0, 0, 0xD0, 0x5B]), "AP open has no recording payload")
        let recording = try Gen1ControlCodec.buildCommand(command: Gen1Commands.aiRecord, payload: Data([1]))
        expect(Gen1ControlCodec.parse(recording)?.payload == Data([1]), "Recording remains separate payload")
        expect(!Gen1APImportProtocol.isRecordingRequest(command: 0x37, payload: Data()), "AP request never becomes recording stop")
        expect(Gen1APImportProtocol.blocksRecording(command: 0x37, payload: Data([1]), apActive: true, quarantined: false), "Active AP cannot start recording")
        expect(Gen1APImportProtocol.blocksRecording(command: 0x37, payload: Data([1]), apActive: false, quarantined: true), "Late AP reply window cannot start recording")
        expect(!Gen1APImportProtocol.blocksRecording(command: 0x37, payload: Data([0]), apActive: false, quarantined: true), "Recording shutdown still allowed after AP")
        expect(!Gen1APImportProtocol.blocksRecording(command: 0x37, payload: Data([1]), apActive: false, quarantined: false), "Recording resumes after AP quarantine")
        expect(Gen1APImportProtocol.ownsReply(command: 0x37, sameTarget: true, apActive: true, quarantined: false), "Active AP owns all 0x37 responses including failure 1/2")
        expect(Gen1APImportProtocol.ownsReply(command: 0x37, sameTarget: true, apActive: false, quarantined: true), "Late AP response isolated from recording")
        expect(!Gen1APImportProtocol.ownsReply(command: 0x37, sameTarget: false, apActive: true, quarantined: true), "AP cannot consume another device response")
        expect(!Gen1APImportProtocol.ownsReply(command: 0x38, sameTarget: true, apActive: true, quarantined: true), "AP gate does not consume unrelated commands")
        let decoder = Gen1ControlStreamDecoder()
        for split in 1..<raw.count {
            decoder.reset()
            expect(decoder.append(raw.prefix(split)).isEmpty, "Credential fragment buffered")
            expect(decoder.append(raw.dropFirst(split)) == [frame], "Complete credentials reassembled")
        }

        let target = UUID(), other = UUID()
        let identity = Gen1APImportIdentity(targetID: target, token: UUID())
        expect(identity.matches(savedID: target, connectedID: nil), "BLE drop does not stop target TCP import")
        expect(identity.matches(savedID: target, connectedID: target), "Same target reconnect allowed")
        expect(!identity.matches(savedID: nil, connectedID: target), "Unbind stops import")
        expect(!identity.matches(savedID: other, connectedID: nil), "Account/target switch stops import")
        expect(!identity.matches(savedID: target, connectedID: other), "Different live target stops import")
        let accountIdentity = Gen1APImportIdentity(targetID: target, token: UUID(), accountID: "user:1")
        expect(accountIdentity.matchesAccount("user:1"), "Same account may resume")
        expect(!accountIdentity.matchesAccount(nil), "Logout invalidates import")
        expect(!accountIdentity.matchesAccount("user:2"), "Different account invalidates import")

        var list = Gen1MediaListAccumulator()
        list.begin()
        let firstBatch = (0..<20).map { "\($0).jpg" }
        expect(list.append(Data(firstBatch.joined(separator: ",").utf8)) == 20, "First 20 filenames")
        expect(list.append(Data("20.jpg,21.mp4,0.jpg,../bad.jpg,thumb_1.jpg".utf8)) == 22, "Accumulate subsequent batch and deduplicate")
        list.begin()
        expect(list.append(Data()) == 0, "New list request resets old files")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = Gen1ImportInbox(root: root)
        try expect(try inbox.completedEntries(for: target).isEmpty, "New inbox empty")
        let entry = try inbox.prepare(targetID: target, fileName: "photo.jpg")
        try expect(try inbox.completedEntries(for: target).isEmpty, "Metadata alone not complete")
        let file = inbox.fileURL(for: entry)
        try Data([1, 2, 3]).write(to: file.appendingPathExtension("partial"))
        try expect(try inbox.completedEntries(for: target).isEmpty, "Partial file not eligible for recovery")
        try FileManager.default.moveItem(at: file.appendingPathExtension("partial"), to: file)
        let reopened = Gen1ImportInbox(root: root)
        try expect(try reopened.completedEntries(for: target) == [entry], "Atomic download commit survives restart")
        try expect(try reopened.completedEntries(for: other).isEmpty, "Recovery isolated by target")
        let second = try inbox.prepare(targetID: target, fileName: "photo.jpg")
        expect(file != inbox.fileURL(for: second), "Repeated remote filename cannot overwrite original")
        let owned = try inbox.prepare(targetID: target, fileName: "owned.jpg", accountID: "user:1")
        try Data([3, 4, 5]).write(to: inbox.fileURL(for: owned))
        try expect(try inbox.completedEntries(for: target, accountID: "user:1") == [owned], "Recovery isolated by account")
        try expect(try inbox.completedEntries(for: target, accountID: "user:2").isEmpty, "Another account cannot adopt retained originals")
        try inbox.recordProcessingFailure(owned, reason: "unreadable original")
        let failed = try reopened.completedEntries(for: target, accountID: "user:1")
        expect(failed.count == 1 && failed.first?.processingError == "unreadable original", "Processing failure survives restart")
        try expect(try Data(contentsOf: inbox.fileURL(for: owned)) == Data([3, 4, 5]), "Failure metadata never changes original bytes")
        try expect(try reopened.completedEntries(for: other, accountID: "user:1").isEmpty, "Failure metadata stays scoped to device")
        try expect(try reopened.completedEntries(for: target, accountID: "user:2").isEmpty, "Failure metadata stays scoped to account")
        try inbox.removeCommitted(owned)
        try inbox.removeCommitted(entry)
        try expect(try inbox.completedEntries(for: target).isEmpty, "Remove only committed original inbox")
        do { _ = try inbox.prepare(targetID: target, fileName: "../photo.jpg"); preconditionFailure("Traversal accepted") }
        catch { expect(error as? Gen1APImportError == .invalidFileName, "Reject unsafe source path") }
        print("Gen1 AP import: \(checks) assertions passed")
    }
}
