import SwiftUI

struct TextToSpeechView: View {
    @Bindable var session: TextToSpeechSessionModel
    let close: () -> Void
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var search = ""
    @State private var replacement = ""
    @State private var firstNode: NSRange?
    @State private var secondNode: NSRange?
    @State private var showingExport = false
    private var input: SynthesisInputSnapshot { session.audio.input(text: session.text) }
    var body: some View {
        if SessionAudioFeatures.speechSynthesisEnabled { enabledBody }
    }
    private var enabledBody: some View {
        VStack(spacing: 0) {
            editingTools.disabled(session.audio.isGenerating)
            Divider()
            TranscriptEditingTextView(text: $session.text, selection: $selection, isEditable: !session.audio.isGenerating)
                .disabled(session.audio.isGenerating)
                .frame(maxWidth: 900).frame(maxWidth: .infinity)
            Divider()
            SessionAudioPlayerView(audio: session.audio, stale: session.audio.isStale(input))
        }
        .navigationTitle(L10n.text("文字转语音"))
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) { Button("返回", systemImage: "chevron.left", action: close) }
            ToolbarItem { Button("导出文字稿", systemImage: "square.and.arrow.up") { showingExport = true }.disabled(session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.audio.isGenerating) }
            ToolbarItem { Button("设置侧栏", systemImage: "sidebar.right") { session.isShowingInspector.toggle() } }
        }
        .inspector(isPresented: $session.isShowingInspector) {
            Form { SpeechSynthesisControls(audio: session.audio, text: session.text, independent: true) }
                .formStyle(.grouped).inspectorColumnWidth(min: 240, ideal: 280, max: 340)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if session.audio.isGenerating { Button("取消生成") { session.audio.cancel() }; ProgressView(value: session.audio.progress).frame(width: 120) }
                else { Button("开始生成音频", systemImage: "waveform") { session.audio.generate(input) }.primaryActionStyle().disabled(!generationAllowed) }
            }.controlSize(.large).padding(14).background(.regularMaterial, in: Capsule()).padding(.bottom, 14)
        }
        .sheet(isPresented: $showingExport) {
            CompanionExportSheet(asset: session.audio.asset, defaultName: L10n.text("文字转语音"), approximateTimeline: true,
                                 warning: { format, _ in session.audio.exportWarning(input: input, format: format) },
                                 makeData: { format, name, _ in
                try TranscriptExporter.makeData(format: format, title: name, source: L10n.text("文字转语音"), language: "", duration: max(Double(session.text.count) / 5, 1),
                                                text: session.text, segments: [], hasManualEdits: true)
            }, onSuccess: {}, close: { showingExport = false })
        }
        .onDisappear { session.audio.player.stop() }
        .onChange(of: session.text) { _, _ in firstNode = nil; secondNode = nil }
    }
    private var generationAllowed: Bool {
        !session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && session.audio.detectedTextDigest == SynthesisInputSnapshot.digest(session.text)
            && session.audio.detectedLanguage.permits(allowAll: SpeechSynthesisPreferences.shared.allowAll,
                                                            englishConfirmed: session.audio.confirmedTextDigest == SynthesisInputSnapshot.digest(session.text))
            && SpeechVoiceCatalog.independentEntryAllowed(allowAll: SpeechSynthesisPreferences.shared.allowAll, effectiveLanguage: SpeechVoiceCatalog.effectiveInterfaceLanguage, hasVoices: !session.audio.catalog.voices.isEmpty)
    }
    private var editingTools: some View {
        ViewThatFits(in: .horizontal) {
            HStack { searchTools; nodeTools }
            VStack(alignment: .leading) { HStack { searchTools }; HStack { nodeTools } }
        }.padding(12)
    }
    @ViewBuilder private var searchTools: some View {
        TextField("查找…", text: $search).frame(width: 130).onSubmit(find)
        Button("查找下一个", systemImage: "magnifyingglass", action: find).disabled(search.isEmpty)
        TextField("替换为…", text: $replacement).frame(width: 130)
        Button("替换选中") { apply(TranscriptTextEditing.replacing(session.text, range: selection, with: replacement)) }.disabled(selection.length == 0)
        Button("全部替换") { if !search.isEmpty { session.text = session.text.replacingOccurrences(of: search, with: replacement, options: [.caseInsensitive, .diacriticInsensitive]) } }.disabled(search.isEmpty)
    }
    private var nodeTools: some View {
        Menu("范围编辑") {
            Button("设为节点一") { firstNode = selection }
            Button("设为节点二") { secondNode = selection }
            Button("删除节点前") { apply(TranscriptTextEditing.deletingBefore(session.text, node: selection)) }
            Button("删除节点后") { apply(TranscriptTextEditing.deletingAfter(session.text, node: selection)) }
            Button("删除两节点之间") { if let firstNode, let secondNode { apply(TranscriptTextEditing.deletingBetween(session.text, first: firstNode, second: secondNode)) } }.disabled(firstNode == nil || secondNode == nil)
        }
    }
    private func find() { if let found = TranscriptTextEditing.find(search, in: session.text, after: selection) { selection = found } }
    private func apply(_ result: (String, NSRange)?) { if let result { session.text = result.0; selection = result.1; firstNode = nil; secondNode = nil } }
}
