import Combine
import CoreLocation
import Foundation
import NetworkExtension

/// A page-scoped, optional SSID lookup. It requests authorization without starting
/// location updates; a denied permission or unavailable SSID leaves manual entry usable.
@MainActor
final class CurrentWifiSSIDReader: NSObject, ObservableObject, CLLocationManagerDelegate {
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()
    private var requestID: UUID?
    private var completion: ((String?) -> Void)?
    private var requestedAuthorization = false
    private var requestedAccuracy = false
    private var accuracyRequestInFlight = false
    private var readInFlight = false
    private var readTimeout: Task<Void, Never>?

    func start(completion: @escaping (String?) -> Void) {
        cancel()
        requestID = UUID()
        self.completion = completion
        requestedAuthorization = false
        requestedAccuracy = false
        accuracyRequestInFlight = false
        log("started")
        handleAuthorization()
    }

    /// Invalidates permission and network callbacks after leaving the form or editing it.
    func cancel() {
        if requestID != nil { log("cancelled") }
        requestID = nil
        completion = nil
        readInFlight = false
        readTimeout?.cancel()
        readTimeout = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.handleAuthorization() }
    }

    private func handleAuthorization() {
        guard let requestID else { return }
        let status = locationManager.authorizationStatus
        log("authorization=\(status.rawValue) accuracy=\(locationManager.accuracyAuthorization.rawValue)")
        switch status {
        case .notDetermined:
            guard !requestedAuthorization else { return }
            requestedAuthorization = true
            log("request when-in-use authorization")
            locationManager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            finish(nil, reason: "location_authorization_unavailable")
        case .authorizedAlways, .authorizedWhenInUse:
            if locationManager.accuracyAuthorization == .fullAccuracy {
                readSSID()
            } else if !requestedAccuracy {
                requestedAccuracy = true
                accuracyRequestInFlight = true
                log("request temporary precise authorization")
                locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "WiFiSSIDAutofill") { [weak self] error in
                    let errorCode = (error as NSError?)?.code
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == requestID else { return }
                        self.accuracyRequestInFlight = false
                        self.log("temporary precise authorization returned errorCode=\(errorCode.map(String.init) ?? "none")")
                        self.handleAuthorization()
                    }
                }
            } else if !accuracyRequestInFlight {
                finish(nil, reason: "precise_authorization_unavailable")
            }
        @unknown default:
            finish(nil, reason: "unknown_authorization")
        }
    }

    private func readSSID() {
        guard let requestID, !readInFlight else { return }
        readInFlight = true
        log("reading current network")
        // Do not let a missing system callback retain the form indefinitely.
        readTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, self.requestID == requestID else { return }
            self.finish(nil, reason: "ssid_read_timeout")
        }
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            // SSIDs are byte-sensitive identifiers; preserve whitespace and Unicode.
            let ssid = network?.ssid
            Task { @MainActor [weak self] in
                guard let self, self.requestID == requestID else { return }
                let value = ssid?.isEmpty == false ? ssid : nil
                self.finish(value, reason: value == nil ? "ssid_unavailable_reason_not_exposed" : "ssid_available")
            }
        }
    }

    private func finish(_ ssid: String?, reason: String) {
        guard requestID != nil, let completion else { return }
        log("finished reason=\(reason) ssidBytes=\(ssid?.utf8.count ?? 0)")
        requestID = nil
        self.completion = nil
        readInFlight = false
        readTimeout?.cancel()
        readTimeout = nil
        completion(ssid)
    }

    private func log(_ message: String) {
        DebugLogStore.logWiFi("Wi-Fi 名称自动填写", detail: "request=\(requestID?.uuidString ?? "none") \(message)")
    }
}
