import SwiftUI

struct AgreementDetailView: View {
    let type: AgreementType

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var languageManager = AppLanguageManager.shared

    private var blocks: [AgreementBlock] {
        AgreementContentLoader.loadBlocks(type: type)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .paragraph(let paragraph):
                            paragraphView(paragraph)
                        case .table(let rows):
                            AgreementPermissionTable(rows: rows)
                                .padding(.top, 12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .padding(.top, 15)
                .padding(.bottom, 20)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
    }

    /// 对齐 Android `addParagraph`：标题 16sp、正文 14sp，行距 +4，块间距 12。
    private func paragraphView(_ paragraph: AgreementParagraph) -> some View {
        Text(paragraph.text)
            .font(AppTheme.notoSansSC(
                size: paragraph.title ? 16 : 14,
                weight: (paragraph.bold || paragraph.title) ? .bold : .regular
            ))
            .foregroundStyle(AppTheme.primaryText)
            .lineSpacing(4)
            .multilineTextAlignment(paragraph.center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: paragraph.center ? .center : .leading)
            .padding(.top, 12)
    }

    private var navigationBar: some View {
        ZStack {
            Text(languageManager.text(type.title, en: type.englishTitle))
                .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .padding(.horizontal, 44)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 40, alignment: .leading)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 40)
    }
}

/// 隐私政策权限表：对齐 Android `addTable`，4 列定宽 + 1px 边框。
private struct AgreementPermissionTable: View {
    let rows: [[AgreementTableCell]]

    @State private var totalWidth: CGFloat = 0

    private var columnCount: Int { AgreementContentLoader.tableColumnCount }
    private var weights: [CGFloat] { AgreementContentLoader.tableColumnWeights }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { index in
                        cellView(row.indices.contains(index) ? row[index] : nil, at: index)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: AgreementTableWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(AgreementTableWidthKey.self) { width in
            totalWidth = width
        }
    }

    private func cellView(_ cell: AgreementTableCell?, at index: Int) -> some View {
        // 首列与 fw7 单元格加粗、末列居中，与安卓一致。
        Text(cell?.text ?? "")
            .font(AppTheme.notoSansSC(
                size: 12,
                weight: (cell?.bold ?? false) || index == 0 ? .bold : .regular
            ))
            .foregroundStyle(AppTheme.primaryText)
            .lineSpacing(2.5)
            .multilineTextAlignment(index == columnCount - 1 ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(
                width: columnWidth(at: index),
                alignment: index == columnCount - 1 ? .center : .leading
            )
            .frame(maxHeight: .infinity)
            .overlay(
                Rectangle()
                    .stroke(Color(red: 0.13, green: 0.13, blue: 0.13), lineWidth: 1)
            )
    }

    private func columnWidth(at index: Int) -> CGFloat? {
        guard totalWidth > 0 else { return nil }
        let weight = weights.indices.contains(index) ? weights[index] : 1
        return totalWidth * weight / weights.reduce(0, +)
    }
}

private struct AgreementTableWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#Preview {
    CompatibleNavigationStack {
        AgreementDetailView(type: .service)
    }
}
