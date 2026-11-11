import AppKit

/// Hides lines of one pane by giving them no glyphs and no height, so "show only N lines
/// around differences" can fold away unchanged text while editing and undo keep working.
/// Paragraph spacing (the filler rows) of a hidden line is kept.
final class HiddenLines: NSObject, NSLayoutManagerDelegate {
    /// Start offset (UTF-16) of every line, and whether each line is hidden.
    private(set) var lineStarts: [Int] = []
    private(set) var hidden: [Bool] = []
    private(set) var isActive = false
    var rowHeight: CGFloat = 0

    /// Updates which lines are hidden. Returns true when anything changed.
    func update(lineStarts: [Int], hidden: [Bool]) -> Bool {
        let active = hidden.contains(true)
        guard active != isActive || (active && (hidden != self.hidden || lineStarts != self.lineStarts)) else {
            self.lineStarts = lineStarts
            self.hidden = hidden
            return false
        }
        self.lineStarts = lineStarts
        self.hidden = hidden
        isActive = active
        return true
    }

    private func line(of charIndex: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= charIndex { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func isHidden(char index: Int) -> Bool {
        guard isActive, !lineStarts.isEmpty else { return false }
        let l = line(of: index)
        return l < hidden.count && hidden[l]
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard isActive, let text = layoutManager.textStorage?.string as NSString? else { return 0 }
        var newProps = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for i in 0..<glyphRange.length where isHidden(char: charIndexes[i]) {
            // Keep the line break itself, or the typesetter would join the line with the next one.
            if charIndexes[i] < text.length, text.character(at: charIndexes[i]) == 0x0A { continue }
            newProps[i] = .null
            changed = true
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: newProps, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard isActive, glyphRange.length > 0 else { return false }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        guard isHidden(char: charIndex) else { return false }
        // Drop the text row but keep the paragraph spacing below it (the filler rows).
        let style = layoutManager.textStorage?.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle
        lineFragmentRect.pointee.size.height = style?.paragraphSpacing ?? 0
        lineFragmentUsedRect.pointee.size.height = 0
        return true
    }
}
