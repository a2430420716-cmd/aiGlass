import SwiftUI

struct FeedbackView: View {
    @Binding var showsTabBar: Bool
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession
    @State private var expandedQuestionID: Int?
    @State private var isLoadingProblems = false

    private var problemItems: [ProblemItem] {
        authSession.problemFAQItems
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    fillProblemButton

                    problemListSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .task {
            await loadProblemList()
        }
    }

    @ViewBuilder
    private var problemListSection: some View {
        if isLoadingProblems, problemItems.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if problemItems.isEmpty {
            Text(L10n.t("暂无常见问题", "No FAQs yet"))
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(problemItems.enumerated()), id: \.element.id) { index, item in
                    FAQRowView(
                        item: item,
                        isExpanded: expandedQuestionID == item.id
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedQuestionID = expandedQuestionID == item.id ? nil : item.id
                        }
                    }

                    if index < problemItems.count - 1 {
                        Divider()
                            .overlay(Color(red: 0.92, green: 0.92, blue: 0.92))
                            .padding(.vertical, 14)
                    }
                }
            }
        }
    }

    private func loadProblemList() async {
        if problemItems.isEmpty {
            isLoadingProblems = true
        }
        defer { isLoadingProblems = false }
        await authSession.refreshProblemFAQList()
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("问题反馈", "Feedback"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 44, alignment: .leading)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var fillProblemButton: some View {
        NavigationLink {
            FeedbackFormView()
                .environmentObject(authSession)
        } label: {
            Text(L10n.t("填写问题", "Describe the issue"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.93, green: 0.88, blue: 0.96),
                            Color(red: 0.86, green: 0.94, blue: 0.98)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

private struct FAQRowView: View {
    let item: ProblemItem
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(item.title)
                    .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(AppTheme.primaryText)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .padding(.top, 6)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            if isExpanded {
                FAQHTMLContentView(html: item.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

#Preview {
    CompatibleNavigationStack {
        FeedbackView(showsTabBar: .constant(true))
            .environmentObject(AuthSession())
    }
}
