import Foundation

// In-memory collaborators for the extracted production controller. These tests
// never use actual Bluetooth, playback, network, app resources, or user defaults.
final class AstraA1BleManager {
    let target = UUID()
    var deviceGeneration = DeviceGeneration.gen1G5K61
    var isDeviceAvailable = true
    var deviceBluetoothIdentifier: String?
    var savedPeripheralUUIDString: String?
    var gen1GuideEventSessionID: UUID?
    var gen1GuideEventTargetID: UUID?
    var gen1GuideEventHandler: ((UUID, Date, Int, Int) -> Void)?
    var gen1GuideMediaHandler: ((UUID, Date, UInt8) -> Void)?
    var guideEventHandler: ((UInt8) -> Void)?
    var sentSteps: [Int] = []
    var sentModes: [Bool] = []
    init() {
        deviceBluetoothIdentifier = target.uuidString
        savedPeripheralUUIDString = target.uuidString
    }
    func setGuideStep(_ step: Int) -> Bool {
        sentSteps.append(step)
        return isDeviceAvailable
    }
    func setGuideModeEnabled(_ enabled: Bool) -> Bool {
        sentModes.append(enabled)
        return isDeviceAvailable
    }
}

enum AstraA1BleProtocol {
    enum GuideEventType: UInt8 {
        case cameraClick = 1, cameraLongPress, touchClick, touchSwipe
        case touchDoubleClick, touchTripleClick, touchLongPress
    }
}

struct DeviceGuideItem: Equatable {
    let marker: String
    static let newbieGuideDefaults = (1...9).map { DeviceGuideItem(marker: "default-\($0)") }
}

enum DeviceService {
    static var suspended = false
    static var pending: [CheckedContinuation<[DeviceGuideItem], any Error>] = []
    static func fetchDeviceGuide(modelName: String, token: String?) async throws -> [DeviceGuideItem] {
        if suspended {
            // Deliberately ignores cancellation, like an already-completing request.
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        return DeviceGuideItem.newbieGuideDefaults
    }
    static func finishPending(marker: String) {
        let requests = pending
        pending.removeAll()
        for request in requests {
            request.resume(returning: (1...9).map { DeviceGuideItem(marker: "\(marker)-\($0)") })
        }
    }
}

enum L10n {
    static func t(_ chinese: String, _ english: String) -> String { chinese }
}

final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Int] = [:]
    var writes: [(String, Int)] = []
    func set(_ value: Int, forKey key: String) {
        values[key] = value
        writes.append((key, value))
    }
}

enum Bundle {
    struct ResourceBundle {
        func url(forResource resource: String, withExtension ext: String, subdirectory: String? = nil) -> URL? {
            URL(fileURLWithPath: "/fake-guide-resources/\(resource).\(ext)")
        }
    }
    static let main = ResourceBundle()
}

final class AVAudioPlayer {
    struct Operation: Equatable {
        let name: String
        let track: String
    }
    static var operations: [Operation] = []
    let track: String
    var isPlaying = false
    var numberOfLoops = 0
    init(contentsOf url: URL) throws { track = url.deletingPathExtension().lastPathComponent }
    func prepareToPlay() {}
    func play() -> Bool {
        isPlaying = true
        Self.operations.append(.init(name: "play", track: track))
        return true
    }
    func pause() {
        isPlaying = false
        Self.operations.append(.init(name: "pause", track: track))
    }
    func stop() {
        isPlaying = false
        Self.operations.append(.init(name: "stop", track: track))
    }
}

enum AVAudioSession {
    static let interruptionNotification = Notification.Name("fakeGuideInterruption")
    static let routeChangeNotification = Notification.Name("fakeGuideRouteChange")
}
let AVAudioSessionInterruptionTypeKey = "fakeInterruptionType"
let AVAudioSessionRouteChangeReasonKey = "fakeRouteReason"

enum GlassesAudioRouteController {
    enum Mode { case playback }
    struct Snapshot { let detail: String }
    static let connectionDiagnosticSnapshot = Snapshot(detail: "fake_route=glasses")
    static func activate(_ mode: Mode) throws {}
}

enum DebugLogStore {
    static var events: [(title: String, detail: String)] = []
    static func logBLEEvent(_ title: String, detail: String) { events.append((title, detail)) }
}

@main
struct Gen1GuideControllerTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func drain() async {
        for _ in 0..<8 { await Task.yield() }
    }

    static func fixture(step: Int) async -> (NewbieGuideController, AstraA1BleManager) {
        let controller = NewbieGuideController()
        let ble = AstraA1BleManager()
        controller.start(ble: ble, modelName: "", token: nil)
        await drain()
        expect(ble.sentSteps == [1], "Start synchronizes first guide step")
        expect(ble.gen1GuideEventHandler != nil && ble.gen1GuideMediaHandler != nil, "Start registers both Gen1 callbacks")
        expect(ble.gen1GuideEventTargetID == ble.target, "Callbacks are owned by target identity")
        expect(!controller.isLoading, "Empty model uses local guide content")
        for _ in 1..<step { controller.skipCurrentStep() }
        expect(controller.stepIndex == step - 1, "Skip reaches requested UI step")
        expect(ble.sentSteps == Array(1...step), "Each skipped step synchronizes next device step")
        AVAudioPlayer.operations.removeAll()
        DebugLogStore.events.removeAll()
        return (controller, ble)
    }

    static func media(_ ble: AstraA1BleManager, _ command: UInt8, source: UUID? = nil, at: Date = Date()) {
        ble.gen1GuideMediaHandler?(source ?? ble.target, at, command)
    }

    static func ack(_ ble: AstraA1BleManager, _ step: Int, result: Int = 1, source: UUID? = nil, at: Date = Date()) {
        ble.gen1GuideEventHandler?(source ?? ble.target, at, step, result)
    }

    static var plays: [AVAudioPlayer.Operation] { AVAudioPlayer.operations.filter { $0.name == "play" } }
    static var pauses: [AVAudioPlayer.Operation] { AVAudioPlayer.operations.filter { $0.name == "pause" } }

    static func main() async {
        for ackFirst in [false, true] {
            let (controller, ble) = await fixture(step: 8)
            if ackFirst {
                ack(ble, 8)
                expect(controller.stepIndex == 8, "ACK advances pause step to step 9")
                media(ble, 0x6B)
            } else {
                media(ble, 0x6B)
                expect(controller.stepIndex == 7, "Pause notification alone does not advance step 8")
                expect(pauses.count == 1, "Pause notification controls existing player")
                media(ble, 0x6B)
                expect(pauses.count == 1, "Duplicate pause notification does not repeat action")
                ack(ble, 8)
            }
            ack(ble, 8)
            media(ble, 0x6B)
            expect(controller.stepIndex == 8, "Duplicate ACK and late pause cannot skip step 9")
            expect(pauses.count == 1, "Pause runs exactly once regardless of callback order")
            expect(plays.isEmpty, "Advancing pause step never starts more playback")
            expect(ble.sentSteps.filter { $0 == 9 }.count == 1, "Step 9 command sent once")
            expect(DebugLogStore.events.contains { $0.title == "引导完成回包处理" && $0.detail.contains("receivedStep=8") }, "ACK log records received step")
            expect(DebugLogStore.events.contains { $0.title == "引导媒体事件处理" && $0.detail.contains("0x6B") }, "Pause log records command and decision")
            ack(ble, 9)
            expect(controller.isCompleted, "Step 9 ACK completes guide")
            expect(ble.sentSteps.last == 0, "Completion exits device guide mode")
            controller.stop()
        }

        for item: (step: Int, command: UInt8, track: String) in [
            (4, 0x6A, "newbie_guide_music_2"),
            (6, 0x6C, "newbie_guide_music_3"),
            (7, 0x6D, "newbie_guide_music_1")
        ] {
            for ackFirst in [false, true] {
                let (controller, ble) = await fixture(step: item.step)
                if ackFirst {
                    ack(ble, item.step)
                    media(ble, item.command)
                } else {
                    media(ble, item.command)
                    expect(controller.stepIndex == item.step - 1, "Track control alone does not advance guide")
                    media(ble, item.command)
                    ack(ble, item.step)
                }
                media(ble, item.command)
                ack(ble, item.step)
                expect(plays == [.init(name: "play", track: item.track)], "Play/next/previous operates once in either callback order")
                expect(controller.stepIndex == item.step, "Track step completes once")
                expect(ble.sentSteps.filter { $0 == item.step + 1 }.count == 1, "Track completion sends one next-step command")
                controller.stop()
            }
        }

        do {
            let (controller, ble) = await fixture(step: 6)
            media(ble, 0x6C)
            ble.isDeviceAvailable = false
            ack(ble, 6)
            expect(controller.stepIndex == 5, "ACK received while unavailable does not advance")
            ble.isDeviceAvailable = true
            media(ble, 0x6C)
            ack(ble, 6)
            expect(plays == [.init(name: "play", track: "newbie_guide_music_3")], "Same-target reconnect preserves media deduplication")
            expect(controller.stepIndex == 6, "Same-target reconnect accepts valid current-step completion")
            expect(DebugLogStore.events.contains { $0.detail.contains("reason=device_unavailable") }, "Unavailable callback rejection logged")
            controller.stop()
        }

        do {
            let (controller, ble) = await fixture(step: 8)
            let other = UUID()
            media(ble, 0x6B, source: other)
            ack(ble, 8, source: other)
            media(ble, 0x6B, at: .distantPast)
            ack(ble, 8, at: .distantPast)
            ble.savedPeripheralUUIDString = other.uuidString
            media(ble, 0x6B)
            ack(ble, 8)
            ble.savedPeripheralUUIDString = ble.target.uuidString
            let originalSession = ble.gen1GuideEventSessionID
            ble.gen1GuideEventSessionID = UUID()
            media(ble, 0x6B)
            ack(ble, 8)
            ble.gen1GuideEventSessionID = originalSession
            expect(AVAudioPlayer.operations.isEmpty, "Wrong target, obsolete timestamps and replaced session cannot operate player")
            expect(controller.stepIndex == 7, "Rejected callbacks cannot advance UI")
            for reason in ["target_changed", "callback_before_session_started", "session_replaced"] {
                expect(DebugLogStore.events.contains { $0.detail.contains("reason=\(reason)") }, "Rejection reason is logged: \(reason)")
            }
            ack(ble, 7)
            ack(ble, 8, result: 0)
            ack(ble, 8, result: 0xE3)
            media(ble, 0x6A)
            expect(AVAudioPlayer.operations.isEmpty && controller.stepIndex == 7, "Wrong step, failure, BUSY and wrong media are inert")
            ack(ble, 8)
            expect(pauses.count == 1 && controller.stepIndex == 8, "Rejected callbacks do not poison later valid completion")
            controller.stop()
        }

        do {
            let (controller, ble) = await fixture(step: 8)
            let oldAck = ble.gen1GuideEventHandler!
            let oldMedia = ble.gen1GuideMediaHandler!
            controller.stop()
            let stoppedCommands = ble.sentSteps
            AVAudioPlayer.operations.removeAll()
            oldMedia(ble.target, Date(), 0x6B)
            oldAck(ble.target, Date(), 8, 1)
            expect(AVAudioPlayer.operations.isEmpty, "Captured callbacks after stop cannot operate player")
            expect(controller.stepIndex == 7 && ble.sentSteps == stoppedCommands, "Captured callbacks after stop cannot advance or send commands")
            expect(ble.gen1GuideEventHandler == nil && ble.gen1GuideMediaHandler == nil, "Stop detaches owned callbacks")
            expect(DebugLogStore.events.contains { $0.detail.contains("reason=page_inactive") }, "After-stop callback rejection logged")

            controller.start(ble: ble, modelName: "", token: nil)
            await drain()
            AVAudioPlayer.operations.removeAll()
            let restartedCommands = ble.sentSteps
            oldMedia(ble.target, Date(), 0x6B)
            oldAck(ble.target, Date(), 8, 1)
            expect(AVAudioPlayer.operations.isEmpty && ble.sentSteps == restartedCommands, "Callbacks from previous page session cannot act on new session")
            expect(controller.stepIndex == 7, "Previous-session ACK cannot advance restarted controller")
            ack(ble, 8)
            expect(controller.stepIndex == 8, "New-session callback still works")
            controller.stop()
        }

        do {
            let (oldController, ble) = await fixture(step: 8)
            let replacement = NewbieGuideController()
            replacement.start(ble: ble, modelName: "", token: nil)
            await drain()
            for _ in 1..<6 { replacement.skipCurrentStep() }
            let newSession = ble.gen1GuideEventSessionID
            let newCommands = ble.sentSteps
            let writesBeforeOldActions = UserDefaults.standard.writes.count
            oldController.skipCurrentStep()
            oldController.restart()
            expect(oldController.stepIndex == 7, "Replaced controller buttons cannot mutate its pending step")
            expect(replacement.stepIndex == 5, "Replaced controller buttons cannot mutate new UI")
            expect(ble.sentSteps == newCommands, "Replaced controller buttons cannot send commands")
            expect(UserDefaults.standard.writes.count == writesBeforeOldActions, "Replaced controller buttons cannot overwrite current persisted step")
            oldController.stop()
            expect(ble.gen1GuideEventSessionID == newSession, "Stopping old controller preserves new session ownership")
            expect(ble.gen1GuideEventHandler != nil && ble.gen1GuideMediaHandler != nil, "Stopping old controller preserves new callbacks")
            expect(ble.sentSteps == newCommands, "Stopping old controller cannot exit new device guide")
            expect(UserDefaults.standard.writes.count == writesBeforeOldActions, "Stopping old controller cannot clear new persisted step")
            expect(UserDefaults.standard.values["blueSettingData"] == 6, "Replacement remains on persisted step 6")
            AVAudioPlayer.operations.removeAll()
            media(ble, 0x6C)
            ack(ble, 6)
            expect(plays == [.init(name: "play", track: "newbie_guide_music_3")], "Replacement player remains usable after old controller stops")
            expect(replacement.stepIndex == 6, "Replacement callback advances current UI after old controller stops")
            replacement.stop()
        }

        do {
            DeviceService.suspended = true
            let oldController = NewbieGuideController()
            let ble = AstraA1BleManager()
            oldController.start(ble: ble, modelName: "OldSlowModel", token: nil)
            await drain()
            expect(DeviceService.pending.count == 1, "Old controller has pending guide data")
            oldController.skipCurrentStep()
            oldController.skipCurrentStep()
            let replacement = NewbieGuideController()
            replacement.start(ble: ble, modelName: "", token: nil)
            await drain()
            for _ in 1..<6 { replacement.skipCurrentStep() }
            let writesBeforeResponse = UserDefaults.standard.writes.count
            DeviceService.finishPending(marker: "replaced-session")
            await drain()
            expect(UserDefaults.standard.writes.count == writesBeforeResponse, "Replaced controller network response cannot overwrite new persisted step")
            expect(UserDefaults.standard.values["blueSettingData"] == 6, "New persisted step survives old network response")
            expect(oldController.guideItems == DeviceGuideItem.newbieGuideDefaults, "Replaced controller ignores stale remote content")
            oldController.stop()
            replacement.stop()
            DeviceService.suspended = false
        }

        do {
            DeviceService.suspended = true
            let controller = NewbieGuideController()
            let ble = AstraA1BleManager()
            controller.start(ble: ble, modelName: "RemoteModel", token: nil)
            await drain()
            expect(DeviceService.pending.count == 1, "Guide data request is suspended")
            controller.skipCurrentStep()
            controller.stop()
            let writesAfterStop = UserDefaults.standard.writes.count
            let stepAfterStop = controller.stepIndex
            DeviceService.finishPending(marker: "obsolete")
            await drain()
            expect(controller.guideItems == DeviceGuideItem.newbieGuideDefaults, "Late guide response cannot replace content after stop")
            expect(controller.stepIndex == stepAfterStop, "Late guide response cannot replace stopped step")
            expect(UserDefaults.standard.writes.count == writesAfterStop, "Late guide response cannot persist stale step after stop")
            expect(UserDefaults.standard.values["blueSettingData"] == 0, "Stopped guide storage remains cleared")
            DeviceService.suspended = false
        }
        expect(DeviceService.pending.isEmpty, "All fake network continuations completed")
        print("Gen1 guide controller: \(checks) assertions passed")
    }
}
