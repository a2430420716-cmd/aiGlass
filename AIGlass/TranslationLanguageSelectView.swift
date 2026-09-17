import SwiftUI

/// 语言选择：对齐安卓 `TranslationLanguageSelectActivity`。
struct TranslationLanguageSelectView: View {
    @Environment(\.dismiss) private var dismiss

    let selectedLanguage: String
    let onSelect: (String) -> Void

    @State private var keyword = ""

    private var languages: [String] {
        let all = TranslationLanguage.displayNames
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            searchBar
            languageList
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("语言", "Language"))
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

    private var searchBar: some View {
        HStack(spacing: 12) {
            TextField(L10n.t("请输入搜索内容", "Search"), text: $keyword)
                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)

            Rectangle()
                .fill(Color(red: 0.72, green: 0.72, blue: 0.72))
                .frame(width: 1, height: 18)

            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var languageList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(languages, id: \.self) { language in
                    Button {
                        onSelect(language)
                        dismiss()
                    } label: {
                        HStack {
                            Text(language)
                                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                                .foregroundStyle(AppTheme.primaryText)
                            Spacer()
                            Image(systemName: isSelected(language) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(isSelected(language) ? AppTheme.accent : Color(red: 0.78, green: 0.78, blue: 0.78))
                        }
                        .padding(.horizontal, 20)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
    }

    private func isSelected(_ language: String) -> Bool {
        TranslationLanguage.code(forDisplayName: language)
            == TranslationLanguage.code(forDisplayName: selectedLanguage)
    }
}

#Preview {
    CompatibleNavigationStack {
        TranslationLanguageSelectView(selectedLanguage: "中文") { _ in }
    }
}
