import AppKit
import DiffCore

/// A text view that paints diff highlights behind the text.
///
/// Rows are laid out on a fixed grid (every line is exactly `rowHeight` tall). Filler rows
/// for lines that exist only on the other side are made with paragraph spacing, so the
/// text itself stays the real file contents and normal editing and undo keep working.
final class DiffTextView: NSTextView {
    weak var controller: FileCompareController?
    var paneIndex = 0

    /// In merge mode (F9) the plain arrow keys move between differences and copy them.
    override func keyDown(with event: NSEvent) {
        if let c = controller, c.mergeMode,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           let key = event.specialKey {
            switch key {
            case .upArrow: c.previousDifference(); return
            case .downArrow: c.nextDifference(); return
            case .leftArrow: c.copyLeftward(); return
            case .rightArrow: c.copyRightward(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let c = controller, !c.rows.isEmpty else { return }
        let top = c.rowOriginY(in: self, pane: paneIndex)
        let shown = c.shownRows
        guard !shown.isEmpty else { return }
        let first = c.displayRow(atOffset: rect.minY - top)
        let last = c.displayRow(atOffset: rect.maxY - top)

        for d in first...last {
            let r = shown[d]
            let y = top + c.shownTops[d]
            if let color = c.background(row: r, pane: paneIndex) {
                color.setFill()
                NSRect(x: rect.minX, y: y, width: rect.width, height: c.rowHeights[r]).fill()
                if c.rows[r].hunk != nil, c.showsInlineDifferences, let line = c.line(c.rows[r], pane: paneIndex) {
                    drawInline(row: r, line: line, controller: c, rowY: y)
                }
            }
            // A dashed line where unchanged lines are folded away.
            if (d == 0 && r > 0) || (d > 0 && shown[d - 1] != r - 1) {
                NSColor.separatorColor.setStroke()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: rect.minX, y: y + 0.5))
                path.line(to: NSPoint(x: rect.maxX, y: y + 0.5))
                path.setLineDash([4, 3], count: 2, phase: 0)
                path.stroke()
            }
        }
    }

    private func drawInline(row: Int, line: Int, controller c: FileCompareController, rowY: CGFloat) {
        guard let layoutManager, let textContainer else { return }
        let ranges = c.inlineRanges(row: row, pane: paneIndex)
        guard !ranges.isEmpty, let lineStart = c.lineStart(pane: paneIndex, line: line) else { return }
        c.inlineColor(row: row).setFill()
        let length = (string as NSString).length
        for range in ranges {
            let charRange = NSRange(location: lineStart + range.location, length: range.length)
            guard NSMaxRange(charRange) <= length else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            if c.wrapLines {
                // A wrapped change can span several screen lines; fill each piece.
                layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                    var box = rect
                    box.origin.x += self.textContainerOrigin.x
                    box.origin.y += self.textContainerOrigin.y
                    box.size.height = c.rowHeight
                    box.fill()
                }
            } else {
                var box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                box.origin.x += textContainerOrigin.x
                box.origin.y = rowY
                box.size.height = c.rowHeight
                box.fill()
            }
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
        let top = c.rowOriginY(in: tv, pane: tv.paneIndex)
        let visible = tv.visibleRect
        let shown = c.shownRows
        guard !shown.isEmpty else { return }
        let first = c.displayRow(atOffset: visible.minY - top)
        let last = c.displayRow(atOffset: visible.maxY - top)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for d in first...last {
            let row = c.rows[shown[d]]
            guard let line = c.line(row, pane: tv.paneIndex) else { continue }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            let y = convert(NSPoint(x: 0, y: top + c.shownTops[d]), from: tv).y
            if c.isSyncLine(line, pane: tv.paneIndex) {
                NSColor.systemOrange.setFill()
                NSRect(x: 0, y: y, width: ruleThickness, height: 2).fill()
            }
            if c.info[tv.paneIndex].bookmarks.contains(line) {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 3, y: y + 2, width: 6, height: h - 4), xRadius: 2, yRadius: 2).fill()
            }
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (h - size.height) / 2), withAttributes: attrs)
        }
    }
}

/// The scroll view, text view and ruler for one side.
final class DiffPane {
    let scrollView = NSScrollView()
    let textView: DiffTextView
    let hiddenLines = HiddenLines()

    /// Switches between wrapping lines at the pane width and one long line per text line.
    func setWrapping(_ wrap: Bool) {
        guard let container = textView.textContainer else { return }
        scrollView.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        container.widthTracksTextView = wrap
        if wrap {
            // The line-number ruler sits over the left edge of the clip view (as a content inset),
            // so the text gets the clip view's width minus the insets.
            let clip = scrollView.contentView
            let insets = clip.contentInsets
            let width = max(clip.bounds.width - insets.left - insets.right, 50)
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            clip.setBoundsOrigin(NSPoint(x: -insets.left, y: clip.bounds.minY))
            scrollView.reflectScrolledClipView(clip)
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    init(index: Int, font: NSFont) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.delegate = hiddenLines
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        textView = DiffTextView(frame: .zero, textContainer: container)
        textView.paneIndex = index
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
