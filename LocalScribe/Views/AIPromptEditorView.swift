import SwiftUI

struct AIPromptEditorView: View {
    @Bindable var preferences: AIPromptPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("更新行为") {
                Toggle("更新不覆盖提示词", isOn: $preferences.preservesAcrossUpdates)
                Text("开启后，升级声迹时保留下面的自定义提示词；关闭时，新版本会采用新版默认设置并清除旧的自定义内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            promptSection(
                title: "润色提示词",
                help: "可填写常用人名、术语、语气和文字整理偏好。每次任务中输入的临时提示词仍会一并使用。",
                text: $preferences.proofreadInstructions,
                reset: { preferences.reset(.proofread) }
            )

            promptSection(
                title: "总结提示词",
                help: "可填写常用的总结语言、重点和格式。要求添加原文之外信息的内容仍会被拒绝。",
                text: $preferences.summaryInstructions,
                reset: { preferences.reset(.summarize) }
            )

            Section("受保护的规则") {
                Label("输出格式、事实约束、注入防护和结果校验由声迹管理", systemImage: "lock.shield")
                Text("这些规则不会显示在编辑器中，也不会被自定义提示词覆盖，因此普通编辑不会造成 AI 功能无法使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("编辑 AI 提示词")
        .frame(minWidth: 560, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func promptSection(
        title: LocalizedStringKey,
        help: LocalizedStringKey,
        text: Binding<String>,
        reset: @escaping () -> Void
    ) -> some View {
        Section(title) {
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 120)
                .padding(5)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(.secondary.opacity(0.3))
                }
            HStack {
                Text("\(text.wrappedValue.count) / \(AIPromptPreferences.maximumCustomInstructionLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认", action: reset)
                    .disabled(text.wrappedValue.isEmpty)
            }
        }
    }
}
