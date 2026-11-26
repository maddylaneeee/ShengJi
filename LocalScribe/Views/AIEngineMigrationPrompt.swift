import SwiftUI

/// Confirmation for deleting Gemma/NLLB and switching to Apple Intelligence.
struct AIEngineMigrationPromptModifier: ViewModifier {
    let presenter: AIEngineController.Presenter
    @State private var controller = AIEngineController.shared

    func body(content: Content) -> some View {
        content
            .alert("改用 Apple 智能？", isPresented: Binding(
                get: { controller.promptPresenter == presenter },
                set: { if !$0, controller.promptPresenter == presenter { controller.dismissPrompt() } }
            )) {
                Button(controller.pendingItems.isEmpty ? "使用 Apple 智能" : "删除旧模型并使用 Apple 智能") {
                    controller.switchToAppleIntelligence()
                }
                Button("保留旧模型", role: .cancel) { controller.keepLegacyModels() }
            } message: {
                Text(message)
            }
            .alert("无法切换到 Apple 智能", isPresented: Binding(
                get: { controller.migrationError != nil && controller.lastPresenter == presenter },
                set: { if !$0 { controller.migrationError = nil } }
            )) {
                Button("好") { controller.migrationError = nil }
            } message: {
                Text(controller.migrationError ?? "")
            }
    }

    private var message: String {
        var parts = [L10n.text("这台 Mac 已开启 Apple 智能。声迹可以改用 Apple 智能在本机完成翻译、纠错润色与总结，速度更快，无需另外下载模型。")]
        if !controller.pendingItems.isEmpty {
            let list = controller.pendingItems.map { "• \($0.title) · \($0.sizeLabel)" }.joined(separator: "\n")
            parts.append(L10n.format("将永久删除以下旧模型：\n%@\n如需再次使用，可重新下载。", list))
        }
        parts.append(L10n.text("选择保留则继续使用原有模型；之后可在“设置 > 模型”中切换。"))
        return parts.joined(separator: "\n\n")
    }
}

extension View {
    func aiEngineMigrationPrompt(_ presenter: AIEngineController.Presenter) -> some View {
        modifier(AIEngineMigrationPromptModifier(presenter: presenter))
    }
}
