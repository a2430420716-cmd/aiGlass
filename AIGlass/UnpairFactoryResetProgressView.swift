import SwiftUI

struct UnpairFactoryResetProgressView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    ProgressView()
                    Text(L10n.t("等待眼镜恢复出厂设置", "Waiting for Glasses to Reset"))
                        .font(.headline)
                }
                Text(L10n.t(
                    "请按眼镜指示完成操作：\n1. 连续短按 3 次电源键，内侧绿色指示灯闪烁。\n2. 连续短按 3 次拍摄按钮，内侧白色指示灯闪烁。\n\n收到眼镜恢复成功的回复后，App 才会完成解绑。",
                    "Follow the glasses' instructions:\n1. Quickly press the power button 3 times until the inner green light flashes.\n2. Quickly press the capture button 3 times until the inner white light flashes.\n\nThe app unpairs only after the glasses confirm a successful reset."
                ))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .background(AppTheme.cardBackground)
            .foregroundStyle(AppTheme.primaryText)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
    }
}
