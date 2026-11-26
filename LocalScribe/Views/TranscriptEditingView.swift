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
        // Long transcripts (thousands of lines) must not lay out the whole document
        // on every scroll or edit.
        textView.layoutManager?.allowsNonContiguousLayout = true
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
    private let gutterWidth: NSLayoutConstraint

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.scrollView = scrollView
        self.textView = textView
        let gutter = TranscriptLineNumberGutterView(textView: textView, scrollView: scrollView)
        self.gutter = gutter
        self.gutterWidth = gutter.widthAnchor.constraint(equalToConstant: gutter.preferredWidth)
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
            gutterWidth,
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        gutter.onPreferredWidthChange = { [weak self] width in
            guard let self, self.gutterWidth.constant != width else { return }
            self.gutterWidth.constant = width
        }
    }

    required init?(coder: NSCoder) { nil }
}

/// Shared line-number presentation for transcript views. Line numbers are
/// rendered verbatim (never locale-grouped, so 1215 is not shown as "1,215")
/// and their column grows with the largest number instead of wrapping.
enum TranscriptLineNumberFormatting {
    static func label(_ lineNumber: Int) -> String {
        String(lineNumber)
    }

    static func digitCount(_ lineNumber: Int) -> Int {
        String(max(lineNumber, 1)).count
    }

    /// Width for a right-aligned monospaced number column. The default minimum
    /// keeps the existing layout for transcripts below 1,000 lines.
    static func columnWidth(maximumLineNumber: Int, fontSize: CGFloat, minimum: CGFloat = 38, padding: CGFloat = 6) -> CGFloat {
        max(minimum, (CGFloat(digitCount(maximumLineNumber)) * fontSize * 0.62 + padding).rounded(.up))
    }
}

/// UTF-16 offsets of every line start in a text, so line numbers can be found by
/// binary search instead of rescanning the whole prefix of the document.
struct TranscriptLineStartIndex: Equatable {
    private(set) var lineStarts: [Int]

    init(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
    }

    var lineCount: Int { lineStarts.count }

    /// One-based line number containing the UTF-16 offset.
    func lineNumber(atUTF16Offset offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(low, 1)
    }
}

final class TranscriptLineNumberGutterView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var lineIndex: TranscriptLineStartIndex?
    private static let fontSize: CGFloat = 12
    private static let trailingInset: CGFloat = 9
    private static let minimumWidth: CGFloat = 50

    var onPreferredWidthChange: ((CGFloat) -> Void)?
    private(set) var preferredWidth: CGFloat = TranscriptLineNumberGutterView.minimumWidth

    override var isFlipped: Bool { true }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        if let storage = textView.textStorage {
            // Fires for user edits and for programmatic `textView.string` writes,
            // unlike `NSText.didChangeNotification`.
            observers.append(center.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: storage,
                queue: .main
            ) { [weak self] notification in
                guard let storage = notification.object as? NSTextStorage,
                      storage.editedMask.contains(.editedCharacters) else { return }
                MainActor.assumeIsolated { self?.transcriptTextDidChange() }
            })
        }
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.needsDisplay = true } })
        // Rewrapping after a width change moves line starts vertically.
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.needsDisplay = true } })
        transcriptTextDidChange()
    }

    required init?(coder: NSCoder) { nil }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func transcriptTextDidChange() {
        lineIndex = nil
        updatePreferredWidth(lineCount: currentLineIndex().lineCount)
        needsDisplay = true
    }

    private func currentLineIndex() -> TranscriptLineStartIndex {
        if let lineIndex { return lineIndex }
        let index = TranscriptLineStartIndex(textView?.string ?? "")
        lineIndex = index
        return index
    }

    private func updatePreferredWidth(lineCount: Int) {
        let width = TranscriptLineNumberFormatting.columnWidth(
            maximumLineNumber: lineCount,
            fontSize: Self.fontSize,
            minimum: Self.minimumWidth,
            padding: Self.trailingInset + 12
        )
        guard width != preferredWidth else { return }
        preferredWidth = width
        onPreferredWidthChange?(width)
    }

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
            .font: NSFont.monospacedDigitSystemFont(ofSize: Self.fontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let source = textView.string as NSString
        let index = currentLineIndex()
        let maxX = bounds.maxX
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, glyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let safeIndex = min(characterIndex, source.length)
            guard safeIndex == 0 || source.character(at: safeIndex - 1) == 0x0A else { return }
            let lineNumber = index.lineNumber(atUTF16Offset: safeIndex)
            let value = TranscriptLineNumberFormatting.label(lineNumber) as NSString
            let size = value.size(withAttributes: attributes)
            let y = usedRect.minY + textView.textContainerInset.height - visibleRect.minY
            value.draw(at: NSPoint(x: maxX - size.width - Self.trailingInset, y: y), withAttributes: attributes)
        }
    }
}

struct AIChangePreviewView: View {
    let original: String
    let proposed: String

    var body: some View {
        let rows = TranscriptLineDiff.rows(original: original, proposed: proposed)
        let numberWidth = TranscriptLineNumberFormatting.columnWidth(
            maximumLineNumber: rows.map(\.number).max() ?? 1,
            fontSize: 13
        )
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 14) {
                        Rectangle()
                            .fill(row.kind.color.opacity(row.kind == .unchanged ? 0 : 0.85))
                            .frame(width: 4)
                        Text(verbatim: TranscriptLineNumberFormatting.label(row.number))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(row.kind.color)
                            .lineLimit(1)
                            .frame(width: numberWidth, alignment: .trailing)
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
            if oldIndex < old.count, newIndex < new.count,
               !removedOffsets.contains(oldIndex), !insertedOffsets.contains(newIndex) {
                result.append(Row(number: newIndex + 1, text: new[newIndex], kind: .unchanged))
                oldIndex += 1
                newIndex += 1
            } else {
                let removedStart = oldIndex
                let insertedStart = newIndex
                while oldIndex < old.count, removedOffsets.contains(oldIndex) {
                    oldIndex += 1
                }
                while newIndex < new.count, insertedOffsets.contains(newIndex) {
                    newIndex += 1
                }

                let removed = old[removedStart..<oldIndex].enumerated().map { offset, text in
                    Row(number: removedStart + offset + 1, text: text, kind: .removed)
                }
                let inserted = new[insertedStart..<newIndex].enumerated().map { offset, text in
                    Row(number: insertedStart + offset + 1, text: text, kind: .inserted)
                }
                result.append(contentsOf: interleaved(removed: removed, inserted: inserted))
            }
        }

        return result
    }

    private static func lines(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Orders one replaced block so each removed line sits just before the
    /// new line its words went into. When AI joins five fragments into one
    /// sentence, the five red lines appear above that green line instead of
    /// being paired one-to-one and pushed to the end of the block.
    static func interleaved(removed: [Row], inserted: [Row]) -> [Row] {
        guard !removed.isEmpty, !inserted.isEmpty else { return removed + inserted }
        guard let anchors = anchors(removed: removed.map(\.text), inserted: inserted.map(\.text)) else {
            var result: [Row] = []
            for offset in 0..<max(removed.count, inserted.count) {
                if offset < removed.count { result.append(removed[offset]) }
                if offset < inserted.count { result.append(inserted[offset]) }
            }
            return result
        }
        // Sort key: removed lines before (or, when unmatched, after) the new
        // line they belong to; stable within equal keys.
        var keyed: [(key: Int, order: Int, row: Row)] = []
        for (offset, row) in removed.enumerated() {
            let anchor = anchors[offset]
            keyed.append((anchor.index * 3 + (anchor.after ? 2 : 0), offset, row))
        }
        for (offset, row) in inserted.enumerated() {
            keyed.append((offset * 3 + 1, removed.count + offset, row))
        }
        return keyed.sorted { ($0.key, $0.order) < ($1.key, $1.order) }.map(\.row)
    }

    /// For each removed line, the inserted line that received its first
    /// word in an order-preserving word alignment. Unmatched lines follow
    /// the previous removed line. Nil when nothing matches or the block is
    /// too large to align cheaply.
    static func anchors(removed: [String], inserted: [String]) -> [(index: Int, after: Bool)]? {
        let left = removed.enumerated().flatMap { line, text in AFMLineAlignment.tokens(text).map { (line, $0) } }
        let right = inserted.enumerated().flatMap { line, text in AFMLineAlignment.tokens(text).map { (line, $0) } }
        guard !left.isEmpty, !right.isEmpty, left.count * right.count <= 250_000 else { return nil }
        var table = Array(repeating: Array(repeating: 0, count: right.count + 1), count: left.count + 1)
        for a in stride(from: left.count - 1, through: 0, by: -1) {
            for b in stride(from: right.count - 1, through: 0, by: -1) {
                table[a][b] = left[a].1 == right[b].1 ? table[a + 1][b + 1] + 1 : max(table[a + 1][b], table[a][b + 1])
            }
        }
        var firstMatch = [Int?](repeating: nil, count: removed.count)
        var a = 0
        var b = 0
        while a < left.count, b < right.count {
            if left[a].1 == right[b].1 {
                if firstMatch[left[a].0] == nil { firstMatch[left[a].0] = right[b].0 }
                a += 1
                b += 1
            } else if table[a + 1][b] >= table[a][b + 1] {
                a += 1
            } else {
                b += 1
            }
        }
        guard firstMatch.contains(where: { $0 != nil }) else { return nil }
        var result: [(index: Int, after: Bool)] = []
        var last: Int?
        for match in firstMatch {
            if let match {
                let index = max(match, last ?? 0)
                result.append((index, false))
                last = index
            } else {
                result.append((last ?? 0, last != nil))
            }
        }
        return result
    }
}
