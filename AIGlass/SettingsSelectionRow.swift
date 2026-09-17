import SwiftUI

struct SettingsSelectionRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 8)

            SettingsRadioIndicator(isSelected: isSelected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SettingsRadioIndicator: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color(red: 0.82, green: 0.82, blue: 0.82), lineWidth: 1.5)
                .frame(width: 22, height: 22)

            if isSelected {
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 22, height: 22)

                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
    }
}
