import CoreBluetooth
import Foundation
import JL_AdvParse
import JL_HashPair
import JL_OTALib

/// First-generation RCSP OTA uses AE00, separate from the glasses' AE3A control channel.
/// The ordinary BLE manager must suspend its reconnect loop until this transport finishes.
@MainActor
final class Gen1BluetoothOtaTransport: NSObject {
    private let sdk = JL_OTAManager.getOTAManager()
    private let authentication = JLHashHandler()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var activeService: CBService?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var connectionEpoch = UUID()
    private var pendingWrites: [Data] = []
    private var writeInFlight = false
    private var authenticated = false
    private var firmware = Data()
    private var targetIdentifier: UUID?
    private var reconnectMAC: String?
    private var reconnectRequested = false
    private var sessionState = Gen1BluetoothOtaSessionState()
    private var connectionPolicy = Gen1BluetoothOtaConnectionPolicy()
    private var continuation: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttemptTask: Task<Void, Never>?
    private var reconnectReleaseTask: Task<Void, Never>?
    private var reconnectReleasePeripheral: CBPeripheral?
    private var nonconnectableTargets = Set<UUID>()
    private var cancelGraceTask: Task<Void, Never>?
    private var finishingResult: Result<Void, Error>?
    private var onPhaseChanged: ((Gen1BluetoothOtaSessionState.Phase) -> Void)?
    private var log: (String) -> Void = { _ in }
    private var lastLoggedResult: JL_OTAResult?
    private var lastLoggedPercent: Int?
    private var recoveryRecord: Gen1BluetoothOtaRecoveryStore.Record?
    private var requiresLoaderMode = false
    private var validationTask: Task<Void, Never>?

    override init() {
        super.init()
        sdk.delegate = self
        authentication.delegate = self
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func upgrade(data: Data, peripheralIdentifier: UUID,
                 recoveryRecord: Gen1BluetoothOtaRecoveryStore.Record,
                 recoverLoader: Bool = false,
                 validateSession: @escaping @MainActor () throws -> Void,
                 log: @escaping (String) -> Void,
                 onPhaseChanged: @escaping (Gen1BluetoothOtaSessionState.Phase) -> Void) async throws {
        guard continuation == nil, !data.isEmpty else {
            throw TransportError.message("Invalid or already active Bluetooth update")
        }
        firmware = data
        targetIdentifier = peripheralIdentifier
        reconnectMAC = recoverLoader ? recoveryRecord.otaMAC : nil
        requiresLoaderMode = recoverLoader
        reconnectRequested = false
        connectionPolicy = Gen1BluetoothOtaConnectionPolicy()
        nonconnectableTargets.removeAll()
        self.recoveryRecord = recoveryRecord
        self.log = log
        self.onPhaseChanged = onPhaseChanged
        lastLoggedResult = nil
        lastLoggedPercent = nil
        log("RCSP transport started transport=BLE service=AE00 loaderRecovery=\(recoverLoader) firmwareBytes=\(data.count) savedOTAUUID=\(recoveryRecord.otaPeripheralID?.uuidString ?? "none") savedOTAMAC=\(recoveryRecord.otaMAC ?? "none")")
        sdk.delegate = self
        authentication.delegate = self
        sdk.resetOTAManager()
        sdk.bleOnly = true
        try validateSession()
        sessionState = Gen1BluetoothOtaSessionState()
        finishingResult = nil
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                validationTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try validateSession()
                            try await Task.sleep(nanoseconds: 250_000_000)
                        } catch {
                            guard !Task.isCancelled else { return }
                            self?.finish(.failure(error))
                            return
                        }
                    }
                }
                connectionPolicy.begin(now: ProcessInfo.processInfo.systemUptime)
                armTimeout(seconds: UInt64(Gen1BluetoothOtaConnectionPolicy.totalTimeout),
                           message: "连接蓝牙升级服务超时，请保持眼镜开机并重试")
                if central.state == .poweredOn { connectTarget() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func connectTarget() {
        guard continuation != nil, finishingResult == nil else { return }
        guard central.state == .poweredOn, reconnectReleasePeripheral == nil else { return }
        guard connectionPolicy.canAttempt(now: ProcessInfo.processInfo.systemUptime) else { return }
        if let peripheral, peripheral.state != .disconnected {
            return
        }
        if connectionPolicy.shouldRetrieveCachedPeripheral, !requiresLoaderMode,
           reconnectMAC == nil, let targetIdentifier,
           let device = central.retrievePeripherals(withIdentifiers: [targetIdentifier]).first,
           device.state != .disconnecting {
            connect(device, source: "cached UUID")
        } else {
            log("RCSP scan for target reconnectByMAC=\(reconnectMAC != nil) loaderReconnect=\(reconnectRequested) attempts=\(connectionPolicy.attempts)")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    private func connect(_ candidate: CBPeripheral, source: String) {
        guard continuation != nil, finishingResult == nil,
              central.state == .poweredOn, reconnectReleasePeripheral == nil else { return }
        if let peripheral, peripheral.state == .connecting || peripheral.state == .connected {
            return
        }
        guard candidate.state != .disconnecting else {
            log("RCSP connect deferred: target still disconnecting id=\(candidate.identifier)")
            queueReconnectAttempt()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let attempt = connectionPolicy.claim(peripheralID: candidate.identifier,
                                                  isConnectable: true, now: now) else { return }
        reconnectAttemptTask?.cancel()
        reconnectAttemptTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, attempt.deadline - now) * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  self.continuation != nil, self.finishingResult == nil,
                  self.connectionPolicy.expire(attempt, now: ProcessInfo.processInfo.systemUptime) else { return }
            self.reconnectAttemptTask = nil
            self.log("RCSP connection attempt timed out target=\(candidate.identifier) state=\(candidate.state.rawValue) loaderReconnect=\(self.reconnectRequested) attempt=\(self.connectionPolicy.attempts)/\(Gen1BluetoothOtaConnectionPolicy.maximumAttempts); release before rescan")
            self.releaseForReconnect()
        }
        central.stopScan()
        peripheral = candidate
        candidate.delegate = self
        log("RCSP connect target=\(candidate.identifier) state=\(candidate.state.rawValue) source=\(source) reconnect=\(reconnectRequested) attempt=\(connectionPolicy.attempts)")
        central.connect(candidate)
    }

    private func cancelReconnectAttempt() {
        reconnectAttemptTask?.cancel()
        reconnectAttemptTask = nil
        connectionPolicy.cancelAttempt()
    }

    private func clearConnectionForReconnect() {
        connectionEpoch = UUID()
        authentication.stopAuthPair()
        authenticated = false
        pendingWrites.removeAll()
        writeInFlight = false
        writeCharacteristic = nil
        notifyCharacteristic = nil
        activeService = nil
    }

    private func releaseForReconnect() {
        guard continuation != nil, finishingResult == nil, connectionPolicy.isActive,
              reconnectReleasePeripheral == nil else { return }
        cancelReconnectAttempt()
        clearConnectionForReconnect()
        central.stopScan()
        guard let peripheral, peripheral.state != .disconnected else {
            reconnectConnectionEnded()
            return
        }
        reconnectReleasePeripheral = peripheral
        log("RCSP release connection target=\(peripheral.identifier) state=\(peripheral.state.rawValue) loaderReconnect=\(reconnectRequested)")
        central.cancelPeripheralConnection(peripheral)
        reconnectReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.continuation != nil,
                  self.finishingResult == nil, self.reconnectReleasePeripheral === peripheral else { return }
            self.log("RCSP reconnect release timeout target=\(peripheral.identifier)")
            self.reconnectConnectionEnded(releaseTimedOut: true)
        }
    }

    private func reconnectConnectionEnded(releaseTimedOut: Bool = false) {
        cancelReconnectAttempt()
        reconnectReleaseTask?.cancel()
        reconnectReleaseTask = nil
        reconnectReleasePeripheral = nil
        let releasedPeripheral = peripheral
        releasedPeripheral?.delegate = nil
        peripheral = nil
        clearConnectionForReconnect()
        let now = ProcessInfo.processInfo.systemUptime
        switch connectionPolicy.retryActionAfterRelease(now: now, releaseTimedOut: releaseTimedOut) {
        case .none:
            log("RCSP reconnect released; no retry budget remains attempts=\(connectionPolicy.attempts)")
            // Once all bounded BLE attempts are exhausted, the total watchdog
            // cannot produce another connection. Finish now instead of leaving
            // the UI in "waiting for reconnect" for the remaining idle seconds.
            let message = reconnectRequested || requiresLoaderMode
                ? "蓝牙升级重连超时，请重新连接眼镜后检查版本"
                : "连接蓝牙升级服务超时，请保持眼镜开机并重试"
            finish(.failure(TransportError.message(message)))
        case .scan:
            queueReconnectAttempt()
        case .replaceCentral:
            log("RCSP replacing OTA central after stalled connection target=\(releasedPeripheral?.identifier.uuidString ?? "none") attempts=\(connectionPolicy.attempts) remainingSeconds=\(max(0, (connectionPolicy.deadline ?? now) - now)) releaseTimedOut=\(releaseTimedOut); retain SDK and image")
            // didDisconnect can arrive normally even while the next connect on
            // this central would stall. Rebuild for both release paths.
            central.delegate = nil
            central.stopScan()
            if let releasedPeripheral, releasedPeripheral.state != .disconnected {
                central.cancelPeripheralConnection(releasedPeripheral)
            }
            reconnectTask?.cancel()
            reconnectTask = nil
            // didDisconnect already notified the SDK on the callback path.
            if releaseTimedOut { sdk.noteEntityDisconnected() }
            connectionPolicy.centralDidReplace()
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    private func armTimeout(seconds: UInt64, message: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if let self {
                self.log("RCSP timeout seconds=\(seconds) phase=\(self.sessionState.phase) target=\(self.peripheral?.identifier.uuidString ?? "none") state=\(self.peripheral?.state.rawValue ?? -1) scanning=\(self.central.isScanning) connectionAttempts=\(self.connectionPolicy.attempts) reason=\(message)")
            }
            self?.finish(.failure(TransportError.message(message)))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard continuation != nil, finishingResult == nil else { return }
        finishingResult = result
        validationTask?.cancel()
        validationTask = nil
        switch result {
        case .success: log("RCSP transfer finished; version still requires confirmation")
        case .failure(let error): log("RCSP finished terminalSuccess=false error=\(error.localizedDescription)")
        }
        connectionEpoch = UUID()
        watchdog?.cancel()
        watchdog = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelReconnectAttempt()
        connectionPolicy.stop()
        reconnectReleaseTask?.cancel()
        reconnectReleaseTask = nil
        reconnectReleasePeripheral = nil
        central.stopScan()
        authentication.stopAuthPair()
        if case .failure = result, authenticated,
           peripheral?.state == .connected, writeCharacteristic != nil {
            // Retain any in-flight RCSP frame's remaining chunks so the following cancel
            // frame stays parseable. Keep delegate, notifications, and continuation alive
            // until its acknowledgement or the bounded teardown deadline.
            cancelGraceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self?.tearDown()
            }
            sdk.cmdOTACancelResult { [weak self] _, _, _ in
                Task { @MainActor in self?.tearDown() }
            }
            return
        }
        tearDown()
    }

    private func tearDown() {
        guard let continuation, let result = finishingResult else { return }
        self.continuation = nil
        cancelGraceTask?.cancel()
        cancelGraceTask = nil
        sdk.delegate = nil
        sdk.noteEntityDisconnected()
        sdk.resetOTAManager()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral?.delegate = nil
        peripheral = nil
        activeService = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        pendingWrites.removeAll()
        writeInFlight = false
        authenticated = false
        firmware = Data()
        recoveryRecord = nil
        onPhaseChanged = nil
        log("RCSP transport released")
        log = { _ in }
        continuation.resume(with: result)
    }

    private func enqueue(_ data: Data) {
        guard continuation != nil, let peripheral, let characteristic = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let size = max(1, peripheral.maximumWriteValueLength(for: type))
        for offset in stride(from: 0, to: data.count, by: size) {
            pendingWrites.append(data.subdata(in: offset..<min(offset + size, data.count)))
        }
        drainWrites()
    }

    private func drainWrites() {
        guard let peripheral, let characteristic = writeCharacteristic, !writeInFlight else { return }
        if characteristic.properties.contains(.writeWithoutResponse) {
            while !pendingWrites.isEmpty, peripheral.canSendWriteWithoutResponse {
                peripheral.writeValue(pendingWrites.removeFirst(), for: characteristic, type: .withoutResponse)
            }
        } else if !pendingWrites.isEmpty {
            writeInFlight = true
            peripheral.writeValue(pendingWrites.removeFirst(), for: characteristic, type: .withResponse)
        }
    }

    private func scheduleReconnect(mac: String? = nil) {
        guard continuation != nil, finishingResult == nil else { return }
        // The SDK can report UUID reconnect before its MAC reconnect result.
        // Keep the more specific address without restarting the reconnect budget.
        if let mac, !mac.isEmpty {
            reconnectMAC = mac
            if var record = recoveryRecord,
               Gen1BluetoothOtaRecoveryStore().record(for: record.targetID) != nil {
                record.otaMAC = mac
                recoveryRecord = record
                Gen1BluetoothOtaRecoveryStore().markImageSubmitted(record)
            }
        }
        guard sessionState.requestReconnect() else { return }
        onPhaseChanged?(sessionState.phase)
        log("RCSP SDK requested reconnect byMAC=\(mac != nil) expectedMAC=\(reconnectMAC ?? "none") originalTarget=\(targetIdentifier?.uuidString ?? "none")")
        if reconnectMAC == nil, let identifier = UUID(uuidString: sdk.mBLE_UUID) { targetIdentifier = identifier }
        reconnectRequested = true
        connectionPolicy.begin(now: ProcessInfo.processInfo.systemUptime)
        nonconnectableTargets.removeAll()
        armTimeout(seconds: UInt64(Gen1BluetoothOtaConnectionPolicy.totalTimeout), message: "蓝牙升级重连超时，请重新连接眼镜后检查版本")
        releaseForReconnect()
    }

    private func queueReconnectAttempt() {
        guard reconnectTask == nil, reconnectReleasePeripheral == nil,
              connectionPolicy.canAttempt(now: ProcessInfo.processInfo.systemUptime) else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.connectionPolicy.isActive,
                  self.continuation != nil, self.finishingResult == nil else { return }
            self.reconnectTask = nil
            self.connectTarget()
        }
    }

    private enum TransportError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }

    private func isActivePeripheral(_ candidate: CBPeripheral) -> Bool {
        continuation != nil && peripheral === candidate
    }
}

extension Gen1BluetoothOtaTransport: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central, continuation != nil else { return }
        log("RCSP central state=\(central.state.rawValue)")
        if central.state == .poweredOn {
            connectTarget()
        } else if central.state != .unknown && central.state != .resetting {
            finish(.failure(TransportError.message("蓝牙不可用，无法升级眼镜")))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, continuation != nil, finishingResult == nil,
              reconnectReleasePeripheral == nil,
              connectionPolicy.canAttempt(now: ProcessInfo.processInfo.systemUptime) else { return }
        let matches: Bool
        if requiresLoaderMode, !reconnectRequested,
           peripheral.identifier == recoveryRecord?.otaPeripheralID {
            matches = true
        } else if let reconnectMAC {
            guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
            matches = JLAdvParse.otaBleMacAddress(reconnectMAC, isEqualToCBAdvDataManufacturerData: data)
        } else {
            matches = peripheral.identifier == targetIdentifier
        }
        guard matches else { return }
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        guard isConnectable else {
            if nonconnectableTargets.insert(peripheral.identifier).inserted {
                log("RCSP matching advertisement not connectable; keep scanning target=\(peripheral.identifier) rssi=\(RSSI)")
            }
            return
        }
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        let manufacturerHex = manufacturer.prefix(64).map { String(format: "%02X", $0) }.joined()
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString).joined(separator: ",")
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "unknown"
        log("RCSP discovered matching target=\(peripheral.identifier) name=\(name.debugDescription) state=\(peripheral.state.rawValue) connectable=\(isConnectable) rssi=\(RSSI) expectedMAC=\(reconnectMAC ?? "none") services=[\(services)] manufacturerBytes=\(manufacturer.count) manufacturerHex=\(manufacturerHex)")
        if reconnectMAC != nil, var record = recoveryRecord {
            record.otaPeripheralID = peripheral.identifier
            recoveryRecord = record
            Gen1BluetoothOtaRecoveryStore().markImageSubmitted(record)
        }
        connect(peripheral, source: reconnectMAC == nil ? "advertised UUID" : "advertised OTA MAC")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central else { central.cancelPeripheralConnection(peripheral); return }
        guard isActivePeripheral(peripheral), finishingResult == nil else { central.cancelPeripheralConnection(peripheral); return }
        guard reconnectReleasePeripheral == nil else {
            log("RCSP late connect while releasing; cancel target=\(peripheral.identifier)")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log("RCSP connected target=\(peripheral.identifier); discover AE00")
        self.peripheral = peripheral
        connectionEpoch = UUID()
        targetIdentifier = peripheral.identifier
        reconnectTask?.cancel()
        reconnectTask = nil
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: "AE00")])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, isActivePeripheral(peripheral) else { return }
        log("RCSP connect failed error=\(error?.localizedDescription ?? "none")")
        if finishingResult != nil { tearDown(); return }
        if connectionPolicy.isActive { reconnectConnectionEnded(); return }
        finish(.failure(error ?? TransportError.message("蓝牙升级服务连接失败")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, isActivePeripheral(peripheral) else { return }
        log("RCSP disconnected target=\(peripheral.identifier) reconnectRequested=\(reconnectRequested) error=\(error?.localizedDescription ?? "none")")
        if finishingResult != nil { tearDown(); return }
        clearConnectionForReconnect()
        sdk.noteEntityDisconnected()
        if connectionPolicy.isActive { reconnectConnectionEnded(); return }
        // Allow an already queued SDK reconnect/reboot result to arrive. Never restart
        // an interrupted transfer solely because the radio disconnected.
        armTimeout(seconds: 8, message: "蓝牙升级连接中断，请重新连接眼镜后检查版本")
    }
}

extension Gen1BluetoothOtaTransport: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isActivePeripheral(peripheral), peripheral.state == .connected,
              finishingResult == nil, reconnectReleasePeripheral == nil else { return }
        if let error { finish(.failure(error)); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "AE00") }) else {
            finish(.failure(TransportError.message("眼镜未提供 AE00 蓝牙升级服务")))
            return
        }
        activeService = service
        peripheral.discoverCharacteristics([CBUUID(string: "AE01"), CBUUID(string: "AE02")], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isActivePeripheral(peripheral), activeService === service,
              peripheral.state == .connected, finishingResult == nil,
              reconnectReleasePeripheral == nil else { return }
        if let error { finish(.failure(error)); return }
        guard let write = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "AE01") }),
              let notify = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "AE02") }),
              write.properties.contains(.write) || write.properties.contains(.writeWithoutResponse) else {
            finish(.failure(TransportError.message("蓝牙升级特征不完整")))
            return
        }
        writeCharacteristic = write
        notifyCharacteristic = notify
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isActivePeripheral(peripheral), notifyCharacteristic === characteristic,
              peripheral.state == .connected, finishingResult == nil,
              reconnectReleasePeripheral == nil else { return }
        if let error { finish(.failure(error)); return }
        guard characteristic.isNotifying else {
            finish(.failure(TransportError.message("无法订阅蓝牙升级通知")))
            return
        }
        sdk.mBLE_UUID = peripheral.identifier.uuidString
        sdk.mBLE_NAME = peripheral.name ?? ""
        authenticated = false
        authentication.hashResetPair()
        let epoch = connectionEpoch
        authentication.bluetoothPairingKey(nil) { [weak self] success in
            Task { @MainActor in
                guard let self, self.isActivePeripheral(peripheral), self.connectionEpoch == epoch,
                      self.finishingResult == nil else { return }
                guard success else {
                    self.finish(.failure(TransportError.message("蓝牙升级设备认证失败")))
                    return
                }
                self.authenticated = true
                self.log("RCSP authenticated; querying device features")
                self.sdk.noteEntityConnected()
                self.sdk.cmdTargetFeature()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isActivePeripheral(peripheral), notifyCharacteristic === characteristic,
              peripheral.state == .connected else { return }
        if let error { finish(.failure(error)); return }
        guard let data = characteristic.value else { return }
        if authenticated { sdk.cmdOtaDataReceive(data) }
        else { authentication.inputPairData(data) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard isActivePeripheral(peripheral), peripheral.state == .connected else { return }
        drainWrites()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isActivePeripheral(peripheral), writeCharacteristic === characteristic,
              peripheral.state == .connected else { return }
        if let error { finish(.failure(error)); return }
        writeInFlight = false
        drainWrites()
    }
}

extension Gen1BluetoothOtaTransport: JLHashHandlerDelegate, JL_OTAManagerDelegate {
    nonisolated func hash(onPairOutputData data: Data) {
        Task { @MainActor [weak self] in self?.enqueue(data) }
    }
    nonisolated func otaDataSend(_ data: Data) {
        Task { @MainActor [weak self] in self?.enqueue(data) }
    }

    nonisolated func otaFeatureResult(_ manager: JL_OTAManager) {
        Task { @MainActor [weak self] in self?.startImageWhenReady() }
    }

    private func startImageWhenReady() {
        guard continuation != nil, finishingResult == nil, authenticated,
              peripheral?.state == .connected, writeCharacteristic != nil else { return }
        // Direct recovery is allowed only when the authenticated vendor feature
        // reply confirms loader/forced OTA mode. A normal device must reconnect
        // through the control channel and pass its ordinary battery gate.
        guard let command = sessionState.imageCommandAfterFeature() else { return }
        if requiresLoaderMode, command == .start, sdk.otaStatus != .force {
            log("RCSP loader recovery rejected otaStatus=\(sdk.otaStatus.rawValue)")
            finish(.failure(TransportError.message("眼镜未处于升级恢复模式，请重新连接眼镜后升级")))
            return
        }
        cancelReconnectAttempt()
        connectionPolicy.stop()
        reconnectRequested = false
        onPhaseChanged?(sessionState.phase)
        log("RCSP image command=\(command) bytes=\(firmware.count) phase=\(sessionState.phase)")
        // Persist before the SDK can write firmware, including an app termination
        // before its first progress callback. Connection/authentication failures
        // before this point neither create nor erase recovery evidence.
        if let recoveryRecord {
            Gen1BluetoothOtaRecoveryStore().markImageSubmitted(recoveryRecord)
            log("RCSP recovery marker persisted before submitting image")
        }
        armTimeout(seconds: 180, message: "蓝牙固件传输超时")
        switch command {
        case .start:
            sdk.cmdOTAData(firmware)
        case .resume:
            // Keep the submitted image and SDK state across the loader reconnect.
            // The device now requests firmware blocks; do not restart the loader.
            sdk.cmdOtaDataIIResult(nil)
        }
    }

    nonisolated func otaCancel() {
        Task { @MainActor [weak self] in
            self?.log("RCSP SDK cancel callback")
            self?.finish(.failure(CancellationError()))
        }
    }

    nonisolated func otaUpgradeResult(_ result: JL_OTAResult, progress: Float) {
        Task { @MainActor [weak self] in self?.handleUpgradeResult(result, progress: progress) }
    }

    private func handleUpgradeResult(_ result: JL_OTAResult, progress: Float) {
        guard continuation != nil, finishingResult == nil else { return }
        let percent = progress.isFinite ? Int((min(1, max(0, progress)) * 100).rounded()) : nil
        if lastLoggedResult != result || lastLoggedPercent != percent {
            log("RCSP result=\(String(format: "0x%04X", result.rawValue)) progress=\(percent.map(String.init) ?? "invalid")")
            lastLoggedResult = result
            lastLoggedPercent = percent
        }
        switch result {
        case .success:
            guard sessionState.receiveSuccess() else {
                log("RCSP early success ignored; second-stage firmware transfer not confirmed")
                return
            }
            onPhaseChanged?(sessionState.phase)
            if let recoveryRecord {
                Gen1BluetoothOtaRecoveryStore().clearAfterSuccess(targetID: recoveryRecord.targetID)
                log("RCSP terminal success; recovery marker cleared")
            }
            finish(.success(Void()))
        case .reboot:
            // A loader reboot is the boundary between transfers, not OTA success.
            // After the entire second transfer, verify the post-reboot version.
            if sessionState.canVerifyAfterReboot {
                log("RCSP reboot after firmware transfer; retaining recovery marker until version confirmation")
                finish(.success(Void()))
            } else {
                scheduleReconnect()
            }
        case .upgrading:
            guard !reconnectRequested, authenticated, let percent else { return }
            sessionState.receiveFirmwareProgress(percent)
            onPhaseChanged?(sessionState.phase)
            armTimeout(seconds: 180, message: "蓝牙升级进度超时，请重新连接眼镜后检查版本")
        case .reconnect, .reconnectUpdateSource:
            scheduleReconnect()
        case .reconnectWithMacAddr:
            scheduleReconnect(mac: sdk.bleAddr)
        case .preparing:
            guard !reconnectRequested, authenticated else { return }
            if let percent { sessionState.receiveLoaderProgress(percent) }
            onPhaseChanged?(sessionState.phase)
            armTimeout(seconds: 180, message: "蓝牙升级设备响应超时")
        case .prepared:
            guard !reconnectRequested, authenticated else { return }
            armTimeout(seconds: 180, message: "蓝牙升级设备响应超时")
        case .disconnect:
            // Releasing a failed service connection can also notify the SDK.
            // That event must not replace the acquisition budget with eight seconds.
            if !connectionPolicy.isActive {
                armTimeout(seconds: 8, message: "蓝牙升级连接中断，请重新连接眼镜后检查版本")
            }
        case .lowPower:
            finish(.failure(TransportError.message("眼镜电量不足，请充电后再升级")))
        case .cancel:
            finish(.failure(CancellationError()))
        default:
            finish(.failure(TransportError.message(String(format: "蓝牙升级失败（RCSP 0x%02X）", result.rawValue))))
        }
    }
}
