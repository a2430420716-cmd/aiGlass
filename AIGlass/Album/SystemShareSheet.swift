import SwiftUI
import UIKit
import Network
import UniformTypeIdentifiers
import ImageIO
import MessageUI

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
        let sources = urls.enumerated().map {
            MediaShareItemSource(url: $0.element, index: $0.offset, diagnostics: diagnostics)
        }
        context.coordinator.sources = sources
        let imageProviders = sources.compactMap { $0.makeImageItemProvider() }
        let controller: UIActivityViewController
        if !sources.isEmpty, imageProviders.count == sources.count {
            // Use concrete encoded-image providers, rather than UIKit choosing a
            // generic UIImage representation for every third-party extension.
            let configuration = UIActivityItemsConfiguration(itemProviders: imageProviders)
            configuration.previewProvider = { index, _, _ in
                guard sources.indices.contains(index) else { return nil }
                return sources[index].makePreviewItemProvider()
            }
            controller = UIActivityViewController(activityItemsConfiguration: configuration)
            diagnostics.recordImageProviders(imageProviders)
        } else {
            controller = UIActivityViewController(activityItems: sources, applicationActivities: nil)
        }
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
    private let imagePlaceholder: UIImage?

    init(url: URL, index: Int, diagnostics: SystemShareDiagnostics) {
        self.url = url
        self.index = index
        self.diagnostics = diagnostics
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        self.type = type
        self.imagePlaceholder = type.conforms(to: .image) ? Self.makeImagePlaceholder(url: url) : nil
        super.init()
        if type.conforms(to: .image) {
            diagnostics.recordImagePlaceholder(index: index, image: imagePlaceholder)
        }
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        // Activity discovery happens before itemForActivityType. An empty UIImage
        // has no encodable image representation for services such as Messages.
        if let imagePlaceholder { return imagePlaceholder }
        return url
    }

    func makeImageItemProvider() -> NSItemProvider? {
        guard imagePlaceholder != nil else { return nil }
        let diagnostics = diagnostics
        let index = index
        let provider = AlbumShareImageProvider.make(url: url) { representation, type, readable in
            Task { @MainActor in
                diagnostics.recordImageProviderLoad(index: index, representation: representation,
                                                    type: type, readable: readable)
            }
        }
        provider?.preferredPresentationStyle = .inline
        return provider
    }

    func makePreviewItemProvider() -> NSItemProvider? {
        guard let imagePlaceholder else { return nil }
        // This bounded image is only a preview. Full-size image requests use the
        // separate provider above, so thumbnails cannot replace the shared photo.
        return NSItemProvider(object: imagePlaceholder)
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        if imagePlaceholder != nil {
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

    private static func makeImagePlaceholder(url: URL) -> UIImage? {
        // Keep only a bounded preview for discovery, not a full-resolution batch.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: thumbnail)
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
        record("系统信息能力", detail: "canSendText=\(MFMessageComposeViewController.canSendText())"
            + " canSendAttachments=\(MFMessageComposeViewController.canSendAttachments())"
            + " supportsJPEG=\(MFMessageComposeViewController.isSupportedAttachmentUTI(UTType.jpeg.identifier))"
            + " supportsPNG=\(MFMessageComposeViewController.isSupportedAttachmentUTI(UTType.png.identifier))"
            + " evidenceLimit=message_compose_capabilities_do_not_guarantee_share_sheet_visibility_or_delivery")
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

    func recordImageProviders(_ providers: [NSItemProvider]) {
        let types = providers.enumerated().map { index, provider in
            "item[\(index)] types=\(provider.registeredTypeIdentifiers.joined(separator: ","))"
        }.joined(separator: "\n")
        record("图片提供器", detail: "configuration=encodedImageProviders itemCount=\(providers.count)\n\(types)")
    }

    func recordImageProviderLoad(index: Int, representation: String, type: String, readable: Bool) {
        record("图片表示加载", detail: "itemIndex=\(index) activityType=notExposedByItemProvider"
            + " representation=\(representation) type=\(type) readableInApp=\(readable)"
            + " evidenceLimit=provider_load_does_not_confirm_recipient_delivery")
    }

    func recordImagePlaceholder(index: Int, image: UIImage?) {
        record("图片占位", detail: "itemIndex=\(index) decoded=\(image != nil)"
            + " representation=\(image != nil ? "UIImage" : "fileURLFallback")"
            + " pixelWidth=\(image?.cgImage?.width ?? 0) pixelHeight=\(image?.cgImage?.height ?? 0)"
            + " fullResolutionDelivery=on_activity_request")
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
