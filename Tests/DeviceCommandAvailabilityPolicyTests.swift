import Foundation

@main
enum DeviceCommandAvailabilityPolicyTests {
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    static func main() {
        discoverySurvivesMissingDeviceCard()
        businessCommandsCannotBypassTheGate()
        shutdownSurvivesMissingDeviceCard()
        rawPacketsMustBeComplete()
        print("Device command availability: \(assertions) assertions passed")
    }

    private static func discoverySurvivesMissingDeviceCard() {
        for name in ["getdevinfo", "hasnewfile", "getdevstat", "geteqmode0", "getvidres0",
                     "getweardet", "getaivsil0", "getwakeup0", "getalgoinf", "getworkpat", "getledbri0"] {
            check(!DeviceCommandAvailabilityPolicy.requiresAvailableDevice(sharedCommand: name, payload: Data()),
                  "\(name) must remain available for binding and recovery")
        }
        for command in [Gen1Commands.snAuth, Gen1Commands.deviceName, Gen1Commands.deviceType,
                        Gen1Commands.systemName, Gen1Commands.bleMac, Gen1Commands.battery,
                        Gen1Commands.bluetoothVersion, Gen1Commands.firmwareVersion,
                        Gen1Commands.storage, Gen1Commands.deviceStatusQuery] {
            check(!DeviceCommandAvailabilityPolicy.requiresAvailableDevice(gen1Command: command, payload: Data()),
                  "Gen1 identity discovery must not depend on completing binding")
        }
        check(!DeviceCommandAvailabilityPolicy.requiresAvailableDevice(
            gen1Command: Gen1Commands.fileList, payload: Data([0, 0])), "Gen1 pending-file query remains read-only")
    }

    private static func businessCommandsCannotBypassTheGate() {
        check(DeviceCommandAvailabilityPolicy.requiresAvailableDevice(
            sharedCommand: "setledbri0", payload: Data([1])), "Brightness SET still requires an available bound device")
        for name in ["takephoto0", "startvideo", "toopenwifi", "otaupload0", "otaupload1", "dllupload0",
                     "deletefile", "recordtime", "setvidres0", "setweardet", "seteqmode0", "setaivsil0",
                     "setwakeup0", "imgrecset0", "imgreccap0", "factreset0", "synctime00", "aivlisten0", "unknown000"] {
            check(DeviceCommandAvailabilityPolicy.requiresAvailableDevice(sharedCommand: name, payload: Data([0])),
                  "\(name) requires a matching device card even for a zero-valued setting")
        }
        for name in ["airecord00", "aivoice000", "trslate000", "guidectrl0"] {
            for payload in [Data(), Data([1]), Data([1, 1]), Data([0, 1])] {
                check(DeviceCommandAvailabilityPolicy.requiresAvailableDevice(sharedCommand: name, payload: payload),
                      "Only exact stop payload is exempt for \(name)")
            }
        }
        for command in [Gen1Commands.takePhoto, Gen1Commands.startVideo, Gen1Commands.firmwareOTA,
                        Gen1Commands.restart, Gen1Commands.factoryReset, Gen1Commands.prepareP2P,
                        Gen1Commands.recordDurationSet, Gen1Commands.wearingSet, Gen1Commands.eqSet,
                        Gen1Commands.imageResolutionSet, Gen1Commands.aiImage, Gen1Commands.syncTime, 0xFF] {
            check(DeviceCommandAvailabilityPolicy.requiresAvailableDevice(gen1Command: command, payload: Data()),
                  "Direct Gen1 business commands cannot bypass the shared command gate")
        }
        for command in [Gen1Commands.aiVoice, Gen1Commands.aiRecord, Gen1Commands.translateRecord] {
            check(DeviceCommandAvailabilityPolicy.requiresAvailableDevice(gen1Command: command, payload: Data([1])),
                  "Gen1 recording/voice start requires a card")
            check(DeviceCommandAvailabilityPolicy.requiresAvailableDevice(gen1Command: command, payload: Data()),
                  "Empty Gen1 start/stop payload must not become a cleanup exemption")
        }
        check(DeviceCommandAvailabilityPolicy.requiresAvailableDevice(
            gen1Command: Gen1Commands.tutorial, payload: Data([1, 0])), "Tutorial start requires a card")
        check(DeviceCommandAvailabilityPolicy.requiresAvailableDevice(
            gen1Command: Gen1Commands.aiImage, payload: Data([4, 1, 0, 1])), "Image retransmission is not shutdown")
    }

    private static func shutdownSurvivesMissingDeviceCard() {
        for name in ["stopvideo0", "closewifi", "closewifi0", "otacancel0", "imgreccan0", "transferok"] {
            check(!DeviceCommandAvailabilityPolicy.requiresAvailableDevice(sharedCommand: name, payload: Data()),
                  "\(name) must release an existing operation after a card disappears")
        }
        for name in ["airecord00", "aivoice000", "trslate000", "guidectrl0"] {
            check(!DeviceCommandAvailabilityPolicy.requiresAvailableDevice(sharedCommand: name, payload: Data([0])),
                  "\(name) stop must still work after a card disappears")
        }
        for command in [Gen1Commands.stopVideo, Gen1Commands.closeHotspot] {
            check(!DeviceCommandAvailabilityPolicy.requiresAvailableDevice(gen1Command: command, payload: Data()),
                  "Gen1 shutdown must remain available")
        }
        for command in [Gen1Commands.aiVoice, Gen1Commands.aiRecord, Gen1Commands.translateRecord] {
            check(!DeviceCommandAvailabilityPolicy.requiresAvailableDevice(gen1Command: command, payload: Data([0])),
                  "Gen1 stop must remain available")
        }
        check(!DeviceCommandAvailabilityPolicy.requiresAvailableDevice(
            gen1Command: Gen1Commands.tutorial, payload: Data([0, 0])), "Tutorial exit must remain available")
        check(!DeviceCommandAvailabilityPolicy.requiresAvailableDevice(
            gen1Command: Gen1Commands.aiImage, payload: Data([5, 0, 8])), "Final image ACK releases an existing transfer")
    }

    private static func rawPacketsMustBeComplete() {
        var packet = Data("takephoto0".utf8)
        packet.append(contentsOf: [0, 0])
        check(DeviceCommandAvailabilityPolicy.sharedCommand(in: packet)?.name == "takephoto0", "Decode a full command")
        check(DeviceCommandAvailabilityPolicy.sharedCommand(in: packet)?.payload.isEmpty == true, "Decode zero payload")
        check(DeviceCommandAvailabilityPolicy.sharedCommand(in: Data(packet.dropLast())) == nil, "Reject truncated header")
        packet.append(1)
        check(DeviceCommandAvailabilityPolicy.sharedCommand(in: packet) == nil, "Reject undeclared bytes")
        packet[10] = 1
        check(DeviceCommandAvailabilityPolicy.sharedCommand(in: packet)?.payload == Data([1]), "Decode declared payload")
        packet[10] = 2
        check(DeviceCommandAvailabilityPolicy.sharedCommand(in: packet) == nil, "Reject truncated payload")
        check(DeviceCommandAvailabilityPolicy.sharedCommand(in: Data(count: 12)) == nil, "Reject empty command name")
    }
}
