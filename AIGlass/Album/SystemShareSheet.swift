import SwiftUI
import UIKit

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
        let controller = UIActivityViewController(
            activityItems: urls,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            context.coordinator.onComplete?()
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

    final class Coordinator {
        let onComplete: (() -> Void)?

        init(onComplete: (() -> Void)?) {
            self.onComplete = onComplete
        }
    }
}
