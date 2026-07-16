import SwiftUI

struct LiveCaptionPanelView: View {
    @Bindable var controller: LiveCaptionController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(controller.isPaused ? L10n.text("已暂停") : L10n.text("实时字幕"), systemImage: "captions.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if controller.isTranslationEnabled {
                    controlButton(controller.showsOriginalText ? "隐藏原文" : "显示原文", symbol: "text.bubble") {
                        controller.toggleOriginalTextDisplay()
                    }
                    .foregroundStyle(controller.showsOriginalText ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }

                if controller.isPaused {
                    controlButton("继续", symbol: "play.fill") {
                        Task { await controller.resume() }
                    }
                } else {
                    controlButton("暂停", symbol: "pause.fill") {
                        Task { await controller.pause() }
                    }
                }

                controlButton("停止", symbol: "stop.fill", role: .destructive) {
                    Task { await controller.stop() }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                SlidingCaptionText(
                    text: controller.primaryText,
                    font: .system(
                        size: controller.isTranslationEnabled ? 28 : 25,
                        weight: .semibold,
                        design: .rounded
                    )
                )
                .frame(height: controller.isTranslationEnabled ? 38 : 34)

                if let secondaryText = controller.secondaryText {
                    VStack(alignment: .leading, spacing: 3) {
                        if let label = controller.secondaryTextLabel {
                            Text(label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Text(secondaryText)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                    }
                }

                if let error = controller.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 116)
        .background {
            shape.fill(
                reduceTransparency
                    ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                    : AnyShapeStyle(.ultraThinMaterial)
            )
            .overlay {
                shape.fill(Color.black.opacity(reduceTransparency ? 0 : 0.06))
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.white.opacity(0.20), lineWidth: 1)
        }
        .contentShape(shape)
    }

    private func controlButton(
        _ title: String,
        symbol: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(L10n.text(title), systemImage: symbol, role: role, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(.regularMaterial, in: Circle())
            .contentShape(Circle())
            .help(title)
    }
}

private struct SlidingCaptionText: View {
    let text: String
    let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targetText = ""
    @State private var renderedText = ""
    @State private var ticker: Task<Void, Never>?

    private let tailAnchor = "live-caption-tail"

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Text(renderedText)
                            .font(font)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)

                        Color.clear
                            .frame(width: 1, height: 1)
                            .id(tailAnchor)
                    }
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                }
                .scrollDisabled(true)
                .onChange(of: renderedText) { _, _ in
                    // Deliberately move in discrete 15 Hz steps instead of a
                    // continuous 60 fps animation to reduce LCD motion trails.
                    proxy.scrollTo(tailAnchor, anchor: .trailing)
                }
            }
        }
        .clipped()
        .accessibilityLabel(renderedText)
        .onAppear {
            targetText = text
            renderedText = reduceMotion ? text : ""
            startTickerIfNeeded()
        }
        .onChange(of: text) { _, newValue in
            targetText = newValue
            if reduceMotion { renderedText = newValue }
        }
        .onChange(of: reduceMotion) { _, isReduced in
            if isReduced { renderedText = targetText }
        }
        .onDisappear {
            ticker?.cancel()
            ticker = nil
        }
    }

    private func startTickerIfNeeded() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                if reduceMotion {
                    renderedText = targetText
                } else {
                    renderedText = LiveCaptionSlidingWindow.nextFrame(
                        current: renderedText,
                        target: targetText
                    )
                }
                try? await Task.sleep(for: LiveCaptionSlidingWindow.updateInterval)
            }
        }
    }
}
