import SwiftUI
import UIKit
import Network
import UniformTypeIdentifiers

struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct SystemShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    var onComplete: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let diagnostics = SystemShareDiagnostics(items: urls, source: "album")
        context.coordinator.diagnostics = diagnostics
        // URL-only activity items can be accepted as generic documents by chat
        // extensions (including a single-file Open In activity for a batch).
        // Advertise photos as native images and videos as their movie types.
        let sources = urls.enumerated().map {
            MediaShareItemSource(url: $0.element, index: $0.offset, diagnostics: diagnostics)
        }
        context.coordinator.sources = sources
        let controller = UIActivityViewController(
            activityItems: sources,
            applicationActivities: nil
        )
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { activityType, completed, returnedItems, error in
            Task { @MainActor in
                diagnostics.recordCompletion(activityType: activityType, completed: completed, returnedItems: returnedItems, error: error)
                coordinator.onComplete?()
            }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = UIView(frame: UIScreen.main.bounds)
            popover.sourceRect = CGRect(
                x: UIScreen.main.bounds.midX,
                y: UIScreen.main.bounds.maxY - 1,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: UIActivityViewController, coordinator: Coordinator) {
        coordinator.diagnostics?.recordDismissal()
    }

    final class Coordinator {
        let onComplete: (() -> Void)?
        var diagnostics: SystemShareDiagnostics?
        var sources: [MediaShareItemSource] = []

        init(onComplete: (() -> Void)?) {
            self.onComplete = onComplete
        }
    }
}

@MainActor
final class MediaShareItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let index: Int
    private let diagnostics: SystemShareDiagnostics
    private let type: UTType
    private var isImage: Bool { type.conforms(to: .image) }

    init(url: URL, index: Int, diagnostics: SystemShareDiagnostics) {
        self.url = url
        self.index = index
        self.diagnostics = diagnostics
        self.type = UTType(filenameExtension: url.pathExtension) ?? .data
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        // Let UIKit choose UIImage's concrete supported representations instead
        // of declaring a file URL (or labeling PNG bytes as JPEG).
        if isImage { return UIImage() }
        return url
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        if isImage {
            // Lazy load per item, without caching a second full-resolution batch.
            let image = UIImage(contentsOfFile: url.path)
            diagnostics.recordRepresentation(index: index, activityType: activityType,
                representation: "UIImage", type: UTType.image.identifier, readable: image != nil)
            return image
        }
        let readable = FileManager.default.isReadableFile(atPath: url.path)
        diagnostics.recordRepresentation(index: index, activityType: activityType,
            representation: "typedFileURL", type: type.identifier, readable: readable)
        return readable ? url : nil
    }

}

/// 只记录系统暴露的分享证据，不记录分享内容、接收人或第三方返回对象。
@MainActor
final class SystemShareDiagnostics {
    private let id = UUID().uuidString
    private let source: String
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var callbackReceived = false
    private let pathMonitor = NWPathMonitor()
    private var defaultPath = "notObserved"
    private var monitoringStopped = false

    init(items: [Any], source: String) {
        self.source = source
        let files = items.prefix(20).enumerated().map { index, item in
            guard let url = item as? URL, url.isFileURL else {
                return "item[\(index)] type=\(String(describing: Swift.type(of: item))) localFile=false"
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.stringValue ?? "unknown"
            return "item[\(index)] file=\(url.lastPathComponent.debugDescription) extension=\(url.pathExtension.debugDescription)"
                + " exists=\(FileManager.default.fileExists(atPath: url.path)) readableInApp=\(FileManager.default.isReadableFile(atPath: url.path)) bytes=\(size)"
        }
        record("开始", detail: "itemCount=\(items.count) metadataTruncated=\(items.count > 20)\n\(files.joined(separator: "\n"))")
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let detail = Self.describePath(path)
            Task { @MainActor [weak self] in
                guard let self, !self.monitoringStopped, self.defaultPath != detail else { return }
                self.defaultPath = detail
                self.record("网络路径变化", detail: "evidenceLimit=path_status_does_not_verify_third_party_server_reachability")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.aiglass.share.diagnostics"))
    }

    deinit { pathMonitor.cancel() }

    func recordCompletion(activityType: UIActivity.ActivityType?, completed: Bool, returnedItems: [Any]?, error: Error?) {
        callbackReceived = true
        let result: String
        if error != nil {
            result = "error"
        } else if completed {
            result = "reportedCompleted"
        } else if activityType == nil {
            result = "cancelledOrDismissed"
        } else {
            result = "notCompleted"
        }
        var detail = "activityType=\(activityType?.rawValue ?? "none") completed=\(completed) result=\(result) returnedItemCount=\(returnedItems?.count ?? 0)"
        var currentError = error.map { $0 as NSError }
        if currentError == nil { detail += "\nerror=none" }
        for depth in 0..<4 {
            guard let nsError = currentError else { break }
            detail += "\nerror[\(depth)].domain=\(nsError.domain.debugDescription) code=\(nsError.code)"
                + " description=\(nsError.localizedDescription.debugDescription)"
                + " failureReason=\(nsError.localizedFailureReason?.debugDescription ?? "none")"
                + " recoverySuggestion=\(nsError.localizedRecoverySuggestion?.debugDescription ?? "none")"
            currentError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        detail += "\nunderlyingErrorsTruncated=\(currentError != nil)"
        detail += "\nevidenceLimit=system_callback_only; third_party_internal_errors_may_not_be_returned; completed_does_not_confirm_recipient_delivery"
        record("系统回调", detail: detail)
        stopMonitoring()
    }

    func recordDismissal() {
        record("界面结束", detail: "callbackObserved=\(callbackReceived); dismissal_alone_does_not_indicate_success_or_failure")
        stopMonitoring()
    }

    func recordRepresentation(index: Int, activityType: UIActivity.ActivityType?,
                              representation: String, type: String, readable: Bool) {
        record("媒体交付", detail: "itemIndex=\(index) activityType=\(activityType?.rawValue ?? "preview") representation=\(representation) type=\(type) readable=\(readable)")
    }

    private func stopMonitoring() {
        monitoringStopped = true
        pathMonitor.pathUpdateHandler = nil
        pathMonitor.cancel()
    }

    nonisolated private static func describePath(_ path: NWPath) -> String {
        let reason = path.status == .unsatisfied ? String(describing: path.unsatisfiedReason) : "notApplicable"
        return "status=\(path.status) usesWiFi=\(path.usesInterfaceType(.wifi)) usesCellular=\(path.usesInterfaceType(.cellular))"
            + " supportsDNS=\(path.supportsDNS) supportsIPv4=\(path.supportsIPv4) supportsIPv6=\(path.supportsIPv6)"
            + " expensive=\(path.isExpensive) constrained=\(path.isConstrained) unsatisfiedReason=\(reason)"
    }

    private func record(_ event: String, detail: String) {
        let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - startedAt)
        let wifiIPv4 = WifiDiagnosticSession.captureInterfaces().selectedIPv4 ?? "none"
        DebugLogStore.logShare(event, detail: "shareID=\(id) source=\(source) elapsedSeconds=\(elapsed)"
            + " appState=\(UIApplication.shared.applicationState.rawValue) wifiIPv4=\(wifiIPv4)"
            + " onGlassesSubnet=\(wifiIPv4.hasPrefix("192.168.4.")) defaultPath=[\(defaultPath)]"
            + " internetReachability=notVerified\n\(detail)")
    }
}
