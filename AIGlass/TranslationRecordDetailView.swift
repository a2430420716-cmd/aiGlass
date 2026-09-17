import SwiftUI

/// 同声传译记录详情：对齐安卓 `TranslationRecordDetailActivity`。
struct TranslationRecordDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let record: SimultaneousTranslationRecord

    @State private var sourcePanelRatio: CGFloat = 0.5
    @State private var dragStartRatio: CGFloat = 0.5
    @State private var isDraggingPanels = false

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            GeometryReader { proxy in
                let separatorHeight: CGFloat = 20
                let available = max(360, proxy.size.height - separatorHeight)
                let sourceHeight = max(120, available * sourcePanelRatio)
                let targetHeight = max(120, available - sourceHeight)

                VStack(spacing: 0) {
                    textPanel(language: record.sourceLanguage, text: record.sourceText)
                        .frame(height: sourceHeight)

                    dragSeparator
                        .frame(height: separatorHeight)
                        .gesture(dragGesture(totalHeight: available))

                    textPanel(language: record.targetLanguage, text: record.targetText)
                        .frame(height: targetHeight)
                }
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
    }

    private var navigationBar: some View {
        ZStack {
            Text(record.title)
                .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .padding(.horizontal, 56)

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

    private func textPanel(language: String, text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(TranslationLanguage.fromDisplayName(language).displayName)
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)

                Text(text)
                    .font(AppTheme.notoSansSC(size: 18, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(6)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var dragSeparator: some View {
        ZStack {
            AppTheme.background
            Capsule()
                .fill(Color(red: 0.84, green: 0.84, blue: 0.84))
                .frame(width: 118, height: 5)
        }
        .contentShape(Rectangle())
    }

    private func dragGesture(totalHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !isDraggingPanels {
                    isDraggingPanels = true
                    dragStartRatio = sourcePanelRatio
                }
                let delta = value.translation.height / max(totalHeight, 1)
                sourcePanelRatio = min(max(dragStartRatio + delta, 0.28), 0.72)
            }
            .onEnded { _ in
                isDraggingPanels = false
                dragStartRatio = sourcePanelRatio
            }
    }
}

#Preview {
    CompatibleNavigationStack {
        TranslationRecordDetailView(
            record: SimultaneousTranslationRecord(
                id: "1",
                title: "同声传译记录20260803120000",
                sourceLanguage: "中文",
                targetLanguage: "英文",
                sourceText: "你好，我想了解这款眼镜的实时翻译功能。",
                targetText: "Hello, I would like to learn about the real-time translation feature.",
                createdAt: Date().timeIntervalSince1970,
                durationMs: 120_000
            )
        )
    }
}
