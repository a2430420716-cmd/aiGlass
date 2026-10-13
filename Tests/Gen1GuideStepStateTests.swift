import Foundation

@main
struct Gen1GuideStepStateTests {
    static var checks = 0

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(), message)
    }

    static let media: [(step: Int, command: UInt8, action: Gen1GuideStepState.MediaAction)] = [
        (4, Gen1Commands.mediaPlay, .play),
        (6, Gen1Commands.mediaNext, .next),
        (7, Gen1Commands.mediaPrevious, .previous),
        (8, Gen1Commands.mediaPause, .pause)
    ]

    /// Test adapter for decoded frames. UI/player integration is covered by the app build;
    /// this harness checks stream integrity and the production step decision policy.
    struct Replay {
        var state = Gen1GuideStepState()
        let decoder = Gen1ControlStreamDecoder()
        var actions: [Gen1GuideStepState.MediaAction] = []
        var completedSteps: [Int] = []

        init(step: Int) { state.waitForStep(step) }

        mutating func feed(_ bytes: Data) {
            for frame in decoder.append(bytes) {
                guard frame.sender == Gen1ControlCodec.device,
                      frame.receiver == Gen1ControlCodec.app,
                      !frame.isBusy else { continue }
                let decision: Gen1GuideStepState.Decision
                if frame.command == Gen1Commands.tutorial {
                    guard frame.payload.count >= 2 else { continue }
                    decision = state.receiveAcknowledgement(
                        step: Int(frame.payload[0]), result: Int(frame.payload[1]))
                } else {
                    decision = state.receiveMedia(command: frame.command)
                }
                switch decision {
                case .ignored: break
                case .media(let action): actions.append(action)
                case .completed(let action):
                    if let action { actions.append(action) }
                    let step = state.waitingStep
                    completedSteps.append(step)
                    state.waitForStep(step < 9 ? step + 1 : 0)
                }
            }
        }
    }

    static func deviceFrame(_ command: UInt8, _ payload: [UInt8] = []) -> Data {
        var result = Data([0xAA, 0x03, 0x02, command,
                           UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        result.append(contentsOf: payload)
        let crc = Gen1ControlCodec.crc16Modbus(result)
        result.append(contentsOf: [UInt8(crc & 0xFF), UInt8(crc >> 8)])
        return result
    }

    static func main() {
        var state = Gen1GuideStepState()
        expect(state.waitingStep == 0, "New guide has no pending step")
        expect(state.receiveMedia(command: 0x6B) == .ignored("no_pending_step"), "Idle guide ignores pause")
        expect(state.receiveAcknowledgement(step: 8, result: 1) == .ignored("no_pending_step"), "Idle guide ignores completion")
        for invalid in [-1, 0, 10, 255] {
            state.waitForStep(invalid)
            expect(state.waitingStep == 0, "Out-of-range step clears pending work")
            expect(state.receiveAcknowledgement(step: invalid, result: 1) == .ignored("no_pending_step"), "Invalid step cannot complete")
        }

        for step in 1...9 {
            let expectedAction = media.first { $0.step == step }?.action
            for item in media {
                state.waitForStep(step)
                let decision = state.receiveMedia(command: item.command)
                if step == item.step {
                    expect(decision == .media(item.action), "Expected gesture changes local player")
                    expect(state.waitingStep == step, "Media event never advances tutorial")
                    expect(state.receiveMedia(command: item.command) == .ignored("media_action_already_handled"), "Duplicate gesture cannot operate player twice")
                    expect(state.receiveAcknowledgement(step: step, result: 1) == .completed(nil), "ACK after gesture completes without repeating player action")
                } else {
                    expect(decision == .ignored("media_does_not_match_step"), "Wrong gesture and non-media steps cannot operate player")
                    expect(state.waitingStep == step, "Wrong gesture leaves current step pending")
                    expect(state.receiveAcknowledgement(step: step, result: 1) == .completed(expectedAction), "Ignored gesture does not consume subsequent completion action")
                }
                expect(state.receiveAcknowledgement(step: step, result: 1) == .ignored("completion_already_handled"), "Each pending step completes once")
                expect(state.receiveMedia(command: item.command) == .ignored("no_pending_step"), "Media after completion cannot repeat action")
            }

            state.waitForStep(step)
            for result in [-1, 0, 2, 3, 0xE3, 0xFF] {
                expect(state.receiveAcknowledgement(step: step, result: result) == .ignored("step_not_completed"), "Only result 1 completes guide")
            }
            for wrongStep in [0, 10, step == 9 ? 1 : step + 1] {
                expect(state.receiveAcknowledgement(step: wrongStep, result: 1) == .ignored("step_mismatch"), "Stale or future step cannot complete current step")
            }
            expect(state.receiveMedia(command: 0xFE) == .ignored("unknown_media_command"), "Unknown command cannot consume pending step")
            expect(state.receiveAcknowledgement(step: step, result: 1) == .completed(expectedAction), "Valid completion remains available after rejected events")
        }

        for item in media {
            // ACK can arrive first. Advancing the view must not let the late media
            // notification repeat play, skip a track twice, or pause the next step.
            state.waitForStep(item.step)
            expect(state.receiveAcknowledgement(step: item.step, result: 1) == .completed(item.action), "ACK-only firmware still controls player")
            state.waitForStep(item.step + 1)
            expect(state.receiveMedia(command: item.command) == .ignored("media_does_not_match_step"), "Late media cannot operate next step")
            expect(state.receiveAcknowledgement(step: item.step, result: 1) == .ignored("step_mismatch"), "Late ACK cannot advance next step")

            // Reconnect preserves the same state object: no waitForStep call.
            state.waitForStep(item.step)
            expect(state.receiveMedia(command: item.command) == .media(item.action), "Initial media event accepted")
            expect(state.receiveMedia(command: item.command) == .ignored("media_action_already_handled"), "Same-target reconnect preserves gesture deduplication")
            expect(state.receiveAcknowledgement(step: item.step, result: 1) == .completed(nil), "Reconnect ACK completes without repeating action")
            expect(state.receiveAcknowledgement(step: item.step, result: 1) == .ignored("completion_already_handled"), "Same-target reconnect preserves completion deduplication")

            // Deliberate restart creates a new pending attempt, including same step.
            state.waitForStep(item.step)
            expect(state.receiveMedia(command: item.command) == .media(item.action), "Restart re-enables gesture on same step")
            expect(state.receiveAcknowledgement(step: item.step, result: 1) == .completed(nil), "Restart has independent completion")
            state.waitForStep(9)
            expect(state.receiveAcknowledgement(step: item.step, result: 1) == .ignored("step_mismatch"), "Skip discards previous pending step")
            expect(state.receiveAcknowledgement(step: 9, result: 1) == .completed(nil), "Final step completes without any player action")
        }

        // Real AA/03/02 wire packets, including BUSY, malformed and unrelated events.
        let packets: [Data] = [
            deviceFrame(0x81, [0xE3]), deviceFrame(0x6B, [0xE3]),
            deviceFrame(0x81), deviceFrame(0x81, [8]), deviceFrame(0xFE, [1]),
            deviceFrame(0x81, [7, 1]), deviceFrame(0x81, [8, 0]),
            deviceFrame(0x81, [8, 0xE3]), deviceFrame(0x6B), deviceFrame(0x6B),
            deviceFrame(0x81, [8, 1]), deviceFrame(0x81, [8, 1]),
            deviceFrame(0x6B), deviceFrame(0x81, [9, 1]), deviceFrame(0x81, [9, 1])
        ]
        let sequence = packets.reduce(into: Data()) { $0.append($1) }
        for split in 0...sequence.count {
            var replay = Replay(step: 8)
            replay.feed(Data(sequence.prefix(split)))
            replay.feed(Data(sequence.dropFirst(split)))
            expect(replay.actions == [.pause], "Every split/merge boundary pauses exactly once")
            expect(replay.completedSteps == [8, 9], "Every split/merge boundary completes only matching ACKs")
            expect(replay.state.waitingStep == 0, "Step 9 ends tutorial without media requirement")
        }
        var bytewise = Replay(step: 8)
        for byte in sequence { bytewise.feed(Data([byte])) }
        expect(bytewise.actions == [.pause], "Single-byte BLE fragments preserve pause exactly once")
        expect(bytewise.completedSteps == [8, 9], "Single-byte BLE fragments preserve completion order")

        for item in media {
            let ack = deviceFrame(0x81, [UInt8(item.step), 1])
            let action = deviceFrame(item.command)
            for packets in [[action, ack], [ack, action]] {
                var replay = Replay(step: item.step)
                replay.feed(packets.reduce(Data(), +))
                expect(replay.actions == [item.action], "Coalesced media/ACK in either order operates player once")
                expect(replay.completedSteps == [item.step], "Coalesced media/ACK in either order advances once")
            }
            for good in [ack, action] {
                var bad = good
                bad[bad.count - 1] ^= 1
                var replay = Replay(step: item.step)
                replay.feed(bad)
                expect(replay.actions.isEmpty, "CRC corruption never operates player")
                expect(replay.completedSteps.isEmpty, "CRC corruption never advances guide")
                replay.feed(ack)
                expect(replay.actions == [item.action], "Decoder recovers next valid ACK after CRC failure")
                expect(replay.completedSteps == [item.step], "CRC failure does not poison following completion")
            }
        }

        var ignored = Replay(step: 8)
        ignored.feed(deviceFrame(0x6B, [0xE3]) + deviceFrame(0x81, [0xE3])
                     + deviceFrame(0x81, [8, 0]) + deviceFrame(0x81, [8, 0xE3])
                     + deviceFrame(0xFE, [8, 1]))
        expect(ignored.actions.isEmpty, "BUSY, non-success and unknown frames produce no player action")
        expect(ignored.completedSteps.isEmpty, "BUSY, non-success and unknown frames never advance")
        expect(ignored.state.waitingStep == 8, "Rejected frames leave original step pending")
        print("Gen1 guide step: \(checks) assertions passed")
    }
}
