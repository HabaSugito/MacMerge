import AppKit
import DiffCore

enum Side: Int {
    case left = 0
    case right = 1

    var other: Side { self == .left ? .right : .left }
}

/// A text view that paints diff highlights behind the text.
///
/// Rows are laid out on a fixed grid (every line is exactly `rowHeight` tall). Filler rows
/// for lines that exist only on the other side are made with paragraph spacing, so the
/// text itself stays the real file contents and normal editing and undo keep working.
final class DiffTextView: NSTextView {
    weak var controller: FileCompareController?
    var side: Side = .left

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let c = controller, !c.rows.isEmpty else { return }
        let h = c.rowHeight
        let top = c.rowOriginY(in: self, side: side)
        let first = max(0, Int(floor((rect.minY - top) / h)))
        let last = min(c.rows.count - 1, Int(floor((rect.maxY - top) / h)))
        guard first <= last else { return }

        for r in first...last {
            let row = c.rows[r]
            guard let hunk = row.hunk else { continue }
            let isCurrent = hunk == c.currentHunk
            let line = side == .left ? row.left : row.right
            let color: NSColor
            if line == nil {
                color = isCurrent ? DiffColors.selectedGhost : DiffColors.ghost
            } else {
                color = isCurrent ? DiffColors.selected : DiffColors.changed
            }
            color.setFill()
            NSRect(x: rect.minX, y: top + CGFloat(r) * h, width: rect.width, height: h).fill()

            if let line, c.showsInlineDifferences {
                drawInline(row: r, line: line, isCurrent: isCurrent, controller: c, rowY: top + CGFloat(r) * h)
            }
        }
    }

    private func drawInline(row: Int, line: Int, isCurrent: Bool, controller c: FileCompareController, rowY: CGFloat) {
        guard let layoutManager, let textContainer else { return }
        let ranges = c.inlineRanges(row: row, side: side)
        guard !ranges.isEmpty, let lineStart = c.lineStart(side: side, line: line) else { return }
        (isCurrent ? DiffColors.selectedWord : DiffColors.word).setFill()
        let length = (string as NSString).length
        for range in ranges {
            let charRange = NSRange(location: lineStart + range.location, length: range.length)
            guard NSMaxRange(charRange) <= length else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            var box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            box.origin.x += textContainerOrigin.x
            box.origin.y = rowY
            box.size.height = c.rowHeight
            box.fill()
        }
    }
}

/// Line numbers drawn next to each pane. Filler rows get no number.
final class LineNumberRuler: NSRulerView {
    weak var textView: DiffTextView?

    init(textView: DiffTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        DiffColors.gutter.setFill()
        bounds.fill()
        guard let tv = textView, let c = tv.controller, !c.rows.isEmpty else { return }
        let h = c.rowHeight
        let top = c.rowOriginY(in: tv, side: tv.side)
        let visible = tv.visibleRect
        let first = max(0, Int(floor((visible.minY - top) / h)))
        let last = min(c.rows.count - 1, Int(floor((visible.maxY - top) / h)))
        guard first <= last else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for r in first...last {
            let row = c.rows[r]
            guard let line = tv.side == .left ? row.left : row.right else { continue }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            let y = convert(NSPoint(x: 0, y: top + CGFloat(r) * h), from: tv).y
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (h - size.height) / 2), withAttributes: attrs)
        }
    }
}

/// The scroll view, text view and ruler for one side.
final class DiffPane {
    let scrollView = NSScrollView()
    let textView: DiffTextView

    init(side: Side, font: NSFont) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        textView = DiffTextView(frame: .zero, textContainer: container)
        textView.side = side
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true

        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
    }
}
