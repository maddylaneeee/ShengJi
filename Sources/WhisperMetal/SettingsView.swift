import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.largeTitle.weight(.semibold))

            InspectorPanel()
                .clipShape(RoundedRectangle(cornerRadius: 12))

            GroupBox("Runtime") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Metal", value: model.detectedGPU)
                    LabeledContent("whisper-cli", value: model.whisperCLIURL?.path ?? "Missing")
                    LabeledContent("Models", value: model.modelDirectory.path)
                }
            }
        }
        .padding(24)
    }
}
