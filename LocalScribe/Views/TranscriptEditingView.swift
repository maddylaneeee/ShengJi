import AppKit
import SwiftUI

struct TranscriptEditingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var isEditable = true

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> TranscriptEditorContainerView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
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
        return TranscriptEditorContainerView(scrollView: scrollView, textView: textView)
    }

    func updateNSView(_ container: TranscriptEditorContainerView, context: Context) {
        let textView = container.textView
        context.coordinator.parent = self
        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
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

final class TranscriptEditorContainerView: NSView {
    let scrollView: NSScrollView
    let textView: NSTextView
    private let gutter: TranscriptLineNumberGutterView

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.scrollView = scrollView
        self.textView = textView
        self.gutter = TranscriptLineNumberGutterView(textView: textView, scrollView: scrollView)
        super.init(frame: .zero)
        clipsToBounds = true
        gutter.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 50),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

final class TranscriptLineNumberGutterView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSText.didChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in self?.needsDisplay = true })
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in self?.needsDisplay = true })
    }

    required init?(coder: NSCoder) { nil }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let scrollView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              !textView.string.isEmpty else { return }
        let visibleRect = scrollView.contentView.bounds
        let containerRect = NSRect(
            x: 0,
            y: max(0, visibleRect.minY - textView.textContainerInset.height),
            width: max(0, visibleRect.width - textView.textContainerInset.width * 2),
            height: visibleRect.height
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, glyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let source = textView.string as NSString
            let safeIndex = min(characterIndex, source.length)
            guard safeIndex == 0 || source.character(at: safeIndex - 1) == 0x0A else { return }
            let prefix = source.substring(to: safeIndex)
            let lineNumber = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let value = "\(lineNumber)" as NSString
            let size = value.size(withAttributes: attributes)
            let y = usedRect.minY + textView.textContainerInset.height - visibleRect.minY
            value.draw(at: NSPoint(x: self.bounds.maxX - size.width - 9, y: y), withAttributes: attributes)
        }
    }
}

struct AIChangePreviewView: View {
    let original: String
    let proposed: String

    private var rows: [TranscriptLineDiff.Row] {
        TranscriptLineDiff.rows(original: original, proposed: proposed)
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

}

enum TranscriptLineDiff {
    struct Row: Identifiable, Equatable {
        let number: Int
        let text: String
        let kind: Kind

        var id: String { "\(kind.id)-\(number)-\(text)" }
    }

    enum Kind: Equatable {
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

    static func rows(original: String, proposed: String) -> [Row] {
        let old = lines(in: original)
        let new = lines(in: proposed)
        let difference = new.difference(from: old)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()

        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removedOffsets.insert(offset)
            case .insert(let offset, _, _):
                insertedOffsets.insert(offset)
            }
        }

        var result: [Row] = []
        result.reserveCapacity(old.count + new.count)
        var oldIndex = 0
        var newIndex = 0

        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removedOffsets.contains(oldIndex) {
                result.append(Row(number: oldIndex + 1, text: old[oldIndex], kind: .removed))
                oldIndex += 1
            } else if newIndex < new.count, insertedOffsets.contains(newIndex) {
                result.append(Row(number: newIndex + 1, text: new[newIndex], kind: .inserted))
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                result.append(Row(number: newIndex + 1, text: new[newIndex], kind: .unchanged))
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < old.count {
                result.append(Row(number: oldIndex + 1, text: old[oldIndex], kind: .removed))
                oldIndex += 1
            } else {
                result.append(Row(number: newIndex + 1, text: new[newIndex], kind: .inserted))
                newIndex += 1
            }
        }

        return result
    }

    private static func lines(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
