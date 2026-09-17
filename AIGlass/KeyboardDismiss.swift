import SwiftUI

extension View {
    func dismissKeyboardOnVerticalDrag(perform dismiss: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    let vertical = abs(value.translation.height)
                    let horizontal = abs(value.translation.width)
                    guard vertical > horizontal, vertical >= 8 else { return }
                    dismiss()
                }
        )
    }
}
