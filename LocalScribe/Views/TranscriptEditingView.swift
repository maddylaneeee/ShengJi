import AppKit
import SwiftUI

struct TranscriptEditingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .systemFont(ofSize: 19)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 10, height: 20)
        textView.textContainer?.lineFragmentPadding = 8
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        scrollView.documentView = textView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.verticalRulerView = TranscriptLineNumberRulerView(textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
            (scrollView.verticalRulerView as? TranscriptLineNumberRulerView)?.needsDisplay = true
        }
        let safe = TranscriptTextEditing.validRange(selection, in: text) ?? NSRange(location: 0, length: 0)
        if textView.selectedRange() != safe {
            textView.setSelectedRange(safe)
            textView.scrollRangeToVisible(safe)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptEditingTextView

        init(parent: TranscriptEditingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.selection = textView.selectedRange()
        }
    }
}

final class TranscriptLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var observers: [NSObjectProtocol] = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        ruleThickness = 50
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        })
        if let contentView = textView.enclosingScrollView?.contentView {
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            })
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [weak self] _, usedRect, _, glyphRange, _ in
            guard let self, let textView = self.textView else { return }
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let source = textView.string as NSString
            let safeIndex = min(characterIndex, source.length)
            guard safeIndex == 0 || source.character(at: safeIndex - 1) == 0x0A else { return }
            let prefix = source.substring(to: safeIndex)
            let lineNumber = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let value = "\(lineNumber)" as NSString
            let size = value.size(withAttributes: attributes)
            let y = usedRect.minY + textView.textContainerInset.height
                - (textView.enclosingScrollView?.contentView.bounds.minY ?? 0)
            value.draw(at: NSPoint(x: bounds.width - size.width - 9, y: y), withAttributes: attributes)
        }
    }
}

struct AIChangePreviewView: View {
    let original: String
    let proposed: String

    private var rows: [DiffRow] {
        let old = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = proposed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if old.count == new.count {
            return old.indices.flatMap { index -> [DiffRow] in
                old[index] == new[index]
                    ? [DiffRow(number: index + 1, text: old[index], kind: .unchanged)]
                    : [
                        DiffRow(number: index + 1, text: old[index], kind: .removed),
                        DiffRow(number: index + 1, text: new[index], kind: .inserted)
                    ]
            }
        }
        return old.enumerated().map { DiffRow(number: $0.offset + 1, text: $0.element, kind: .removed) }
            + new.enumerated().map { DiffRow(number: $0.offset + 1, text: $0.element, kind: .inserted) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 14) {
                        Rectangle()
                            .fill(row.kind.color.opacity(row.kind == .unchanged ? 0 : 0.85))
                            .frame(width: 4)
                        Text("\(row.number)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(row.kind.color)
                            .frame(width: 38, alignment: .trailing)
                        Text(row.text.isEmpty ? " " : row.text)
                            .font(.system(size: 19))
                            .lineSpacing(8)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 7)
                    .padding(.trailing, 20)
                    .background(row.kind.color.opacity(row.kind == .unchanged ? 0 : 0.14))
                }
            }
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
        }
        .accessibilityLabel("AI 修改实时对比")
    }

    private struct DiffRow: Identifiable {
        let number: Int
        let text: String
        let kind: Kind

        var id: String { "\(kind.id)-\(number)-\(text)" }
    }

    private enum Kind {
        case unchanged, removed, inserted
        var id: String {
            switch self {
            case .unchanged: "same"
            case .removed: "removed"
            case .inserted: "inserted"
            }
        }
        var color: Color {
            switch self {
            case .unchanged: .secondary
            case .removed: .red
            case .inserted: .green
            }
        }
    }
}
