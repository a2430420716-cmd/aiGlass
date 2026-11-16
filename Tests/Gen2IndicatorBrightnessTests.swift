import Foundation

@main
enum Gen2IndicatorBrightnessTests {
    private static var assertions = 0

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(value(), message)
    }

    private static func response(_ status: UInt8, _ level: UInt8) -> Data {
        Data(Array("ledbrirsp0".utf8) + [2, 0, status, level])
    }

    static func main() {
        check(Gen2IndicatorBrightnessProtocol.query() == Data([
            0x67, 0x65, 0x74, 0x6C, 0x65, 0x64, 0x62, 0x72, 0x69, 0x30, 0, 0
        ]), "Query must match the documented 12-byte wire fixture")
        for level in IndicatorBrightnessLevel.allCases {
            check(Gen2IndicatorBrightnessProtocol.set(level) == Data([
                0x73, 0x65, 0x74, 0x6C, 0x65, 0x64, 0x62, 0x72, 0x69, 0x30, 1, 0, level.rawValue
            ]), "SET sends level 0/1/2, never 30/60/100")
            check(Gen2IndicatorBrightnessProtocol.parseResponse(response(0, level.rawValue))?.level == level,
                  "All device levels decode")
        }
        for value in [UInt8(3), 30, 60, 100, 255] {
            check(IndicatorBrightnessLevel(rawValue: value) == nil, "Reject percentages and invalid levels")
            check(Gen2IndicatorBrightnessProtocol.parseResponse(response(0, value)) == nil, "Reject invalid response level")
        }
        let valid = response(0, 2)
        let sliced = (Data([255]) + valid).dropFirst()
        check(Gen2IndicatorBrightnessProtocol.parseResponse(sliced)?.level == .high, "Support Data slices")
        check(AstraNotificationFramer.frames(in: valid + response(2, 1)) == [valid, response(2, 1)],
              "Coalesced brightness replies retain wire order")
        check(AstraNotificationFramer.frames(in: Data([255, 254]) + valid) == [valid],
              "Brightness reply survives notification resynchronization")
        var truncatedInfo = Data(Array("getdevinfo".utf8) + [200, 0, 1])
        truncatedInfo.append(valid)
        check(AstraNotificationFramer.frames(in: truncatedInfo).last == valid,
              "Incomplete info response cannot hide brightness ACK")
        check(Gen1CommandAdapter.translate(Gen2IndicatorBrightnessProtocol.query()) == nil,
              "Brightness query must never reach Gen1")
        check(Gen1CommandAdapter.translate(Gen2IndicatorBrightnessProtocol.set(.medium)) == nil,
              "Brightness setting must never reach Gen1")
        for count in 0..<valid.count {
            check(Gen2IndicatorBrightnessProtocol.parseResponse(Data(valid.prefix(count))) == nil, "Reject truncated frames")
        }
        check(Gen2IndicatorBrightnessProtocol.parseResponse(valid + Data([0])) == nil, "Reject extra bytes")
        var wrongLength = valid
        wrongLength[11] = 1
        check(Gen2IndicatorBrightnessProtocol.parseResponse(wrongLength) == nil, "Validate LE length")
        var wrongHeader = valid
        wrongHeader[0] = 0
        check(Gen2IndicatorBrightnessProtocol.parseResponse(wrongHeader) == nil, "Validate command identity")

        var state = Gen2IndicatorBrightnessState()
        check(state.level == nil, "Do not invent a default level")
        let queryID = state.begin(.query)!
        check(state.begin(.set(.low)) == nil, "Serialize automatic query and user SET")
        check(!state.receive(.init(status: 0, level: .high)), "Unsent request cannot consume a stale reply")
        state.recordWrite(id: queryID, accepted: true)
        check(state.level == nil, "Local GATT success is not device confirmation")
        check(!state.recordWrite(id: queryID, accepted: true), "Never resend an accepted write")
        state.receive(.init(status: 0, level: .high))
        check(state.level == .high && !state.isPending && state.result?.failure == nil, "Query applies actual value")
        check(!state.finish(id: queryID, failure: .timeout), "Completed query cannot time out")

        let setID = state.begin(.set(.low))!
        state.recordWrite(id: setID, accepted: true)
        check(state.level == .high, "Selection stays at confirmed level until ACK")
        state.receive(.init(status: 2, level: .medium))
        check(state.level == .medium && state.result?.failure == .storageFailed,
              "NV failure still corrects UI with device's actual level")
        let confirmedSetID = state.begin(.set(.low))!
        state.recordWrite(id: confirmedSetID, accepted: true)
        state.receive(.init(status: 0, level: .low))
        check(state.level == .low && state.result?.failure == nil && !state.isPending,
              "Matching SET acknowledgement confirms the selected level")
        let repeatedID = state.begin(.set(.low))!
        state.recordWrite(id: repeatedID, accepted: true)
        state.receive(.init(status: 0, level: .low))
        check(state.result?.id == repeatedID && state.result?.failure == nil, "Repeated same-level SET can succeed")
        let invalidID = state.begin(.set(.low))!
        state.recordWrite(id: invalidID, accepted: true)
        state.receive(.init(status: 1, level: .high))
        check(state.level == .high && state.result?.failure == .invalidParameter, "Invalid SET corrects actual level")
        let mismatchID = state.begin(.set(.low))!
        state.recordWrite(id: mismatchID, accepted: true)
        state.receive(.init(status: 0, level: .medium))
        check(state.level == .medium && state.result?.failure == .differentLevel,
              "Mismatched ACK must not report requested level as saved")
        let unknownStatusID = state.begin(.query)!
        state.recordWrite(id: unknownStatusID, accepted: true)
        state.receive(.init(status: 99, level: .low))
        check(state.level == .low && state.result?.failure == .rejected(99), "Unknown status retains device value")

        let retryID = state.begin(.set(.high))!
        for attempt in 1...Gen2IndicatorBrightnessState.maximumWriteAttempts {
            check(state.recordWrite(id: retryID, accepted: false), "Allow failed local write attempt \(attempt)")
        }
        check(!state.recordWrite(id: retryID, accepted: false), "Bound failed local writes at eight")
        state.finish(id: retryID, failure: .sendFailed)
        check(!state.isPending && state.level == .low, "Write failure releases pending without guessing")
        check(Gen2IndicatorBrightnessState.retryInterval == 0.25 && Gen2IndicatorBrightnessState.responseTimeout == 3,
              "Use protocol retry interval and ACK timeout")

        let timeoutID = state.begin(.set(.high))!
        state.recordWrite(id: timeoutID, accepted: true)
        state.finish(id: timeoutID, failure: .timeout)
        check(state.level == .low && state.result?.failure == .timeout && !state.isPending,
              "Old firmware timeout keeps confirmed value and permits retry")
        state.receive(.init(status: 0, level: .high))
        check(state.level == .high && state.result?.failure == .timeout,
              "Late ACK may correct actual level but cannot turn timed-out request into success")

        let oldID = state.begin(.query)!
        state.recordWrite(id: oldID, accepted: true)
        state.reset()
        check(state.level == nil && !state.isPending && state.result == nil, "Disconnect clears device-scoped state")
        let newID = state.begin(.set(.medium))!
        check(!state.recordWrite(id: oldID, accepted: true), "Old connection retry cannot send for a new request")
        check(!state.finish(id: oldID, failure: .timeout), "Old connection timeout cannot affect a new request")
        state.recordWrite(id: newID, accepted: true)
        state.receive(.init(status: 0, level: .medium))
        check(state.result?.id == newID && state.level == .medium, "Reconnect confirms only current request")
        print("Gen2 indicator brightness: \(assertions) assertions passed")
    }
}
