import SwiftUI

struct InspectorPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                modelSection
                outputSection
                recognitionSection
                promptSection
                vadSection
                performanceSection
                advancedSection
            }
            .padding(16)
        }
        .padding(.trailing, 18)
        .background(.regularMaterial)
    }

    private var modelSection: some View {
        GroupBox(L.t("Model")) {
            VStack(alignment: .leading, spacing: 10) {
            Picker(L.t("Active model"), selection: Binding(
                get: { model.modelPath },
                set: { model.selectModel($0) }
            )) {
                if model.availableModels.isEmpty {
                    Text(L.t("No local models")).tag("")
                }
                ForEach(model.availableModels, id: \.path) { url in
                    Text(url.lastPathComponent).tag(url.path)
                }
            }
            Button {
                model.pickModelFile()
            } label: {
                Label(L.t("Import GGML Model"), systemImage: "square.and.arrow.down")
            }
            }
        }
    }

    private var outputSection: some View {
        GroupBox(L.t("Output")) {
            VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("Output folder"))
                    .foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(model.outputDirectory)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        model.pickOutputDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                }
            }

            ForEach(OutputFormat.allCases) { format in
                Toggle(format.title, isOn: Binding(
                    get: { model.outputFormats.contains(format) },
                    set: { enabled in
                        if enabled {
                            model.outputFormats.insert(format)
                        } else {
                            model.outputFormats.remove(format)
                        }
                        model.saveSettings()
                    }
                ))
            }
            }
        }
    }

    private var recognitionSection: some View {
        GroupBox(L.t("Recognition")) {
            VStack(alignment: .leading, spacing: 10) {
            Picker(L.t("Task"), selection: $model.task) {
                ForEach(WhisperTask.allCases) { task in
                    Text(L.t(task.title)).tag(task)
                }
            }
            Picker(L.t("Language"), selection: $model.language) {
                Text(L.t("Auto Detect")).tag("auto")
                Text("English").tag("en")
                Text("Chinese").tag("zh")
                Text("Japanese").tag("ja")
                Text("Korean").tag("ko")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Spanish").tag("es")
                Text("Russian").tag("ru")
            }
            Toggle(L.t("Use Metal GPU"), isOn: $model.useMetal)
            Toggle(L.t("Print timestamps"), isOn: $model.printTimestamps)
            Toggle(L.t("Stereo diarization"), isOn: $model.diarize)
            }
        }
    }

    private var promptSection: some View {
        GroupBox(L.t("Prompt")) {
            TextEditor(text: $model.prompt)
                .frame(minHeight: 72)
                .overlay(alignment: .topLeading) {
                if model.prompt.isEmpty {
                    Text(L.t("Initial prompt"))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var vadSection: some View {
        GroupBox(L.t("Voice Activity")) {
            VStack(alignment: .leading, spacing: 10) {
            Toggle(L.t("Use Silero VAD"), isOn: $model.enableVAD)
            Picker(L.t("VAD model"), selection: $model.vadModelPath) {
                if model.availableVADModels.isEmpty {
                    Text("No VAD model").tag("")
                }
                ForEach(model.availableVADModels, id: \.path) { url in
                    Text(url.lastPathComponent).tag(url.path)
                }
            }
            SliderRow(title: L.t("Threshold"), value: $model.vadThreshold, range: 0.1...0.9, step: 0.05, precision: 2)
            Stepper("Min speech: \(model.vadMinSpeechMs) ms", value: $model.vadMinSpeechMs, in: 0...5000, step: 50)
            Stepper("Min silence: \(model.vadMinSilenceMs) ms", value: $model.vadMinSilenceMs, in: 0...5000, step: 50)
            Stepper("Speech pad: \(model.vadSpeechPadMs) ms", value: $model.vadSpeechPadMs, in: 0...2000, step: 10)
            }
        }
    }

    private var performanceSection: some View {
        GroupBox(L.t("Performance")) {
            VStack(alignment: .leading, spacing: 10) {
            Stepper("Threads: \(model.threads)", value: $model.threads, in: 1...max(1, ProcessInfo.processInfo.processorCount))
            Stepper("Processors: \(model.processors)", value: $model.processors, in: 1...8)
            SliderRow(title: "Temperature", value: $model.temperature, range: 0...1, step: 0.05, precision: 2)
            }
        }
    }

    private var advancedSection: some View {
        GroupBox(L.t("Advanced Decoding")) {
            VStack(alignment: .leading, spacing: 10) {
            Stepper("Best of: \(model.bestOf)", value: $model.bestOf, in: 1...20)
            Stepper("Beam size: \(model.beamSize)", value: $model.beamSize, in: 1...20)
            Stepper("Max length: \(model.maxLength)", value: $model.maxLength, in: 0...448)
            Stepper("Max context: \(model.maxContext)", value: $model.maxContext, in: -1...448)
            Toggle("No fallback", isOn: $model.noFallback)
            Toggle("Split on word", isOn: $model.splitOnWord)
            SliderRow(title: "Word threshold", value: $model.wordThreshold, range: 0...1, step: 0.01, precision: 2)
            SliderRow(title: "Entropy", value: $model.entropyThreshold, range: 0...10, step: 0.1, precision: 1)
            SliderRow(title: "No speech", value: $model.noSpeechThreshold, range: 0...1, step: 0.05, precision: 2)
            }
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let precision: Int

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range, step: step)
            Text(value, format: .number.precision(.fractionLength(precision)))
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }
}
