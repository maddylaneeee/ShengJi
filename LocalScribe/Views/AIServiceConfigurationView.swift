import SwiftUI

struct AIServiceConfigurationView: View {
    @Bindable var preferences: AIServicePreferences
    @Environment(\.dismiss) private var dismiss
    private let initialDraft: AIServiceConfiguration?
    private let temporaryKey: String?
    private let injectedSession: URLSession?
    @State private var draft = AIServiceConfiguration()
    @State private var replacementKey = ""
    @State private var deleteKey = false
    @State private var hasSavedKey = false
    @State private var models: [String] = []
    @State private var modelMessage: String?
    @State private var testMessage: String?
    @State private var saveError: String?
    @State private var isVerified = false
    @State private var isBusy = false
    @State private var requestTask: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var drafts: [AIServiceProvider: AIServiceConfiguration] = [:]

    init(preferences: AIServicePreferences, initialDraft: AIServiceConfiguration? = nil,
         temporaryKey: String? = nil, session: URLSession? = nil) {
        self.preferences = preferences
        self.initialDraft = initialDraft
        self.temporaryKey = temporaryKey
        self.injectedSession = session
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("服务", selection: Binding(get: { draft.provider }, set: selectProvider)) {
                        ForEach(AIServiceProvider.allCases) { provider in Text(provider.title).tag(provider) }
                    }
                    if draft.provider == .lmStudio {
                        TextField("本机服务地址", text: $draft.localURL)
                            .help("请在 LM Studio 中启动本机服务并准备文本模型。声迹不会替它下载模型或管理其进程。")
                    } else {
                        LabeledContent("API 地址", value: draft.provider.defaultURL)
                        Label("预览功能", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("云端连接器为预览功能：已通过本地协议模拟，尚未使用正式 key 联调。")
                    }
                    if draft.provider.isCloud {
                        Toggle("我同意向所选服务发送任务文字稿，并承担可能产生的 API 费用", isOn: $draft.cloudConsent)
                    }
                } header: {
                    sectionTitle("AI 服务源", help: draft.provider.privacyDescription)
                }
                Section {
                    SecureField(LocalizedStringKey(draft.provider.isCloud ? "API key" : "Token（可选）"), text: $replacementKey)
                        .disabled(deleteKey)
                        .help(draft.provider.isCloud
                              ? L10n.text("OpenAI 和 DeepSeek 获取模型列表及生成文字均需要有效 API key。")
                              : L10n.text("LM Studio 默认无需 Token；仅在服务端开启认证时需要。"))
                    if hasSavedKey {
                        Label("Keychain 中已有凭据；留空保留原凭据", systemImage: "key.fill")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("保存时删除已有凭据", isOn: $deleteKey)
                    }
                } header: {
                    sectionTitle("凭据", help: L10n.text("凭据仅保存在这台 Mac 的 Keychain，不写入普通设置或恢复文件。无需 key 也可保存配置。"))
                }
                Section {
                    HStack {
                        if !models.isEmpty {
                            Menu("选择模型") {
                                ForEach(models, id: \.self) { id in Button(id) { draft.modelID = id } }
                            }
                        }
                        Button("获取模型列表") { runRequest(testGeneration: false) }
                            .disabled(isBusy || modelListBlocker != nil)
                            .help(modelListBlocker ?? L10n.text("获取服务当前可见的模型。OpenAI 和 DeepSeek 需要有效 API key；LM Studio 需启动本机服务。"))
                    }
                    if let status = modelMessage ?? modelListBlocker {
                        Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    TextField("模型 ID", text: $draft.modelID)
                        .help("可从服务返回的列表选择，也可填写模型 ID。列表不保证每个模型都支持文字生成；请测试连接。无需填写请求 JSON。")
                    Toggle("使用流式响应", isOn: $draft.stream)
                } header: {
                    sectionTitle("模型", help: L10n.text("可从服务返回的列表选择，也可填写模型 ID。列表不保证每个模型都支持文字生成；请测试连接。无需填写请求 JSON。"))
                }
                Section {
                    HStack {
                        Button("测试连接") { runRequest(testGeneration: true) }
                            .disabled(isBusy || !canTest)
                            .help("测试只发送固定的合成短句，不发送你的稿件。云端测试可能产生少量费用。")
                        if isBusy {
                            ProgressView().controlSize(.small)
                            Button("取消") { invalidateRequest() }
                        }
                        if isVerified { Label("已验证", systemImage: "checkmark.circle") }
                    }
                    if let testMessage { Text(testMessage).font(.caption).textSelection(.enabled) }
                } header: {
                    sectionTitle("连接测试", help: L10n.text("测试只发送固定的合成短句，不发送你的稿件。云端测试可能产生少量费用。"))
                }
            }
            .formStyle(.grouped)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 640, height: 600)
        .onAppear {
            if let initialDraft {
                draft = initialDraft
                replacementKey = temporaryKey ?? ""
            } else { load(preferences.provider) }
        }
        .onChange(of: draft) { _, _ in invalidateRequest() }
        .onChange(of: replacementKey) { _, _ in invalidateRequest() }
        .onChange(of: deleteKey) { _, _ in invalidateRequest() }
        .onDisappear { invalidateRequest() }
    }
    private func sectionTitle(_ title: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(title))
            Image(systemName: "info.circle")
                .help(help)
                .accessibilityLabel(help)
        }
    }
    private var modelListBlocker: String? {
        do { return draft.modelListBlocker(key: try effectiveKey()) }
        catch { return error.localizedDescription }
    }
    private var canTest: Bool {
        !draft.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!draft.provider.isCloud || ((!replacementKey.isEmpty || (hasSavedKey && !deleteKey)) && draft.cloudConsent))
    }
    private func load(_ provider: AIServiceProvider) {
        draft = drafts[provider] ?? preferences.configuration(for: provider)
        replacementKey = ""
        deleteKey = false
        models = []
        do { hasSavedKey = try preferences.key(for: provider) != nil }
        catch { hasSavedKey = false; saveError = error.localizedDescription }
    }
    private func selectProvider(_ provider: AIServiceProvider) {
        drafts[draft.provider] = draft
        invalidateRequest()
        load(provider)
    }
    private func invalidateRequest() {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        isBusy = false
        isVerified = false
        modelMessage = nil
        testMessage = nil
        saveError = nil
    }
    private func effectiveKey() throws -> String? {
        if deleteKey { return nil }
        let newKey = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return newKey.isEmpty ? try preferences.key(for: draft.provider) : newKey
    }
    private func runRequest(testGeneration: Bool) {
        invalidateRequest()
        let id = requestID
        do {
            let key = try effectiveKey()
            try draft.validate(key: key, needsModel: testGeneration, needsConsent: testGeneration)
            let client = OpenAICompatibleClient(configuration: draft, key: key, session: injectedSession, totalTimeout: .seconds(30))
            isBusy = true
            requestTask = Task {
                do {
                    if testGeneration {
                        let result = try await client.complete(
                            system: "Return exactly the word OK, without commentary.",
                            data: "Synthetic connection test. Reply OK.", maxTokens: 256)
                        guard !Task.isCancelled, requestID == id else { return }
                        guard result.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else { throw AIServiceError.invalidOutput }
                        isVerified = true
                        testMessage = L10n.text("连接和短文本协议测试通过；实际稿件仍会进行结果校验。")
                    } else {
                        let values = try await client.models()
                        guard !Task.isCancelled, requestID == id else { return }
                        models = values
                        modelMessage = values.isEmpty ? L10n.text("服务未返回模型，请准备文本模型或填写模型 ID。") : L10n.text("模型列表已更新。")
                    }
                } catch is CancellationError {
                } catch {
                    guard !Task.isCancelled, requestID == id else { return }
                    if testGeneration { testMessage = error.localizedDescription }
                    else { modelMessage = error.localizedDescription }
                }
                if requestID == id { isBusy = false; requestTask = nil }
            }
        } catch {
            if testGeneration { testMessage = error.localizedDescription }
            else { modelMessage = error.localizedDescription }
        }
    }
    private func save() {
        invalidateRequest()
        do {
            draft.modelID = draft.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String? = deleteKey ? "" : (replacementKey.isEmpty ? nil : replacementKey)
            try preferences.save(draft, replacementKey: key)
            dismiss()
        } catch { saveError = error.localizedDescription }
    }
}
