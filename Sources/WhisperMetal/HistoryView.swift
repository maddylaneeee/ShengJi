import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L.t("History"))
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                Button {
                    model.logText = ""
                } label: {
                    Label(L.t("Clear Log"), systemImage: "xmark.circle")
                }
                .disabled(model.logText.isEmpty)
            }

            List {
                Section(L.t("Completed Runs")) {
                    if model.history.isEmpty {
                        ContentUnavailableView(L.t("No completed runs"), systemImage: "clock")
                    } else {
                        ForEach(model.history) { item in
                            HStack {
                                Image(systemName: item.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(item.succeeded ? .green : .red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.inputName)
                                    Text(item.outputBase)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.date, style: .time)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section(L.t("Debug Log")) {
                    ScrollView {
                        Text(model.logText.isEmpty ? L.t("No run output yet.") : model.logText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(model.logText.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                    }
                    .frame(minHeight: 180)
                }
            }
        }
        .padding(24)
    }
}
