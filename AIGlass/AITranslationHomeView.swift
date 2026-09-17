import SwiftUI

/// AI 翻译入口：对齐 Android `AiTranslationHomeActivity`。
struct AITranslationHomeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsConversationTranslation = false
    @State private var showsSimultaneousTranslation = false

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            VStack(spacing: 16) {
                translationCard(
                    imageName: "conversation_translation_card",
                    title: L10n.t("对话翻译", "Conversation Translation")
                ) {
                    showsConversationTranslation = true
                }

                translationCard(
                    imageName: "simultaneous_translation_card",
                    title: L10n.t("同声传译", "Simultaneous Interpretation")
                ) {
                    showsSimultaneousTranslation = true
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15)
            .padding(.top, 24)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .compatibleNavigationDestination(isPresented: $showsConversationTranslation) {
            ConversationTranslationView()
        }
        .compatibleNavigationDestination(isPresented: $showsSimultaneousTranslation) {
            SimultaneousTranslationView()
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("AI翻译", "AI Translation"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func translationCard(
        imageName: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 24) {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 185, height: 104)

                Text(title)
                    .font(AppTheme.notoSansSC(size: 18, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 194)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: AppTheme.cardShadow, radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

#Preview {
    CompatibleNavigationStack {
        AITranslationHomeView()
    }
}
