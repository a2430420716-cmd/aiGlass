"""Compile production value models and pairing propagation without UIKit/network services."""
from pathlib import Path
import sys

repo = Path(__file__).resolve().parents[1]


def block(text, marker):
    start = text.index(marker)
    cursor = text.index("{", start) + 1
    depth = 1
    while depth:
        if text[cursor] == "{":
            depth += 1
        elif text[cursor] == "}":
            depth -= 1
        cursor += 1
    return text[start:cursor]


models = [
    block((repo / "AIGlass/Network/UserModels.swift").read_text(encoding="utf-8"), "struct UserDevice:"),
    block((repo / "AIGlass/Network/DeviceService.swift").read_text(encoding="utf-8"), "struct DeviceModelItem:"),
    block((repo / "AIGlass/HomeView.swift").read_text(encoding="utf-8"), "struct DeviceCardData:"),
]
flow = (repo / "AIGlass/PairingFlow.swift").read_text(encoding="utf-8")
methods = [block(flow, name) for name in [
    "    func selectDevice(", "    func refreshSelectedDeviceModel(", "    func startPairing()",
]]
probe = """
struct DeviceGuideItem {}
@MainActor final class PairingBLEProbe {
    var requestedType: APIDeviceType?
    func startPairing(preferredDeviceName: String?, deviceType: APIDeviceType?) { requestedType = deviceType }
}
@MainActor final class DeviceTypePairingProbe {
    var selectedAPIModelName: String?
    var selectedDeviceType: APIDeviceType?
    var selectedEqName: String?
    var selectedPrepareHTML: String?
    var selectedGuideItems: [DeviceGuideItem] = []
    var pairingModel: GlassDeviceModel?
    var hasStartedBind = false
    var isBindingDevice = false
    var bindStatusMessage: String?
    var userConfirmedPairingDevice = false
    var showSearchingSheet = false
    let astraA1BleManager = PairingBLEProbe()
    func cancelPairingAttempt() {}
    func goToPreparation() {}
""" + "\n".join(methods) + "\n}\n"
Path(sys.argv[1]).write_text("import Foundation\n" + "\n".join(models) + probe, encoding="utf-8")
