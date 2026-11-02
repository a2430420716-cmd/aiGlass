import Foundation

@main
enum Gen1BackgroundQueryGateTests {
    static func main() {
        var gate = Gen1BackgroundQueryGate()
        precondition(gate.delay(for: .fileList, at: 100) == 0)
        gate.sent(.fileList, at: 100)
        precondition(gate.delay(for: .fileList, at: 100) == 10,
                     "Initial refresh plus deferred refresh must not send duplicate requests")
        precondition(gate.delay(for: .battery, at: 100) == 0,
                     "Independent query types do not block each other")
        precondition(gate.delay(for: .fileList, at: 102, freshContent: true) == 8,
                     "A file-change notification cannot interleave an outstanding file list")
        gate.received(.fileList, at: 102)
        precondition(gate.delay(for: .fileList, at: 102) == 3,
                     "Navigating back after a reply still respects the page-refresh interval")
        precondition(gate.delay(for: .fileList, at: 102, freshContent: true) == 0.5,
                     "Actual new media bypasses caching after the multi-notification quiet period")
        gate.received(.fileList, at: 102.25)
        precondition(gate.delay(for: .fileList, at: 102.5, freshContent: true) == 0.25,
                     "Later chunks extend the quiet period before a new accumulator can begin")
        precondition(gate.delay(for: .fileList, at: 105) == 0)
        gate.sent(.fileList, at: 105)
        precondition(gate.delay(for: .fileList, at: 114) == 1)
        precondition(gate.delay(for: .fileList, at: 115) == 0,
                     "A missing reply must not suppress refresh permanently")
        gate.sent(.battery, at: 120)
        gate.received(.battery, at: 121)
        precondition(gate.delay(for: .battery, at: 121) == 4)
        gate.reset()
        precondition(gate.delay(for: .battery, at: 122) == 0)
        precondition(gate.delay(for: .fileList, at: 122) == 0,
                     "Reconnecting or switching glasses starts with independent query state")
        print("Gen1 background query gate: 13 assertions passed")
    }
}
