import AppKit
import Combine
import DiffCore

struct PaneInfo {
    /// Where this pane is saved. Nil for panes that cannot be saved (the sides of a conflict file).
    var url: URL?
    var title: String
    var file: TextFile
    var isDirty = false
    var isReadOnly = false
    /// Bookmarked line numbers.
    var bookmarks: Set<Int> = []
}

/// Owns the text panes of a file comparison (2 panes, or 3 for a three-way merge) and keeps
/// them aligned, highlighted and in sync.
@MainActor
final class FileCompareController: NSObject, ObservableObject, NSTextViewDelegate {
    let target: CompareTarget
    private(set) var font = EditorSettings.font
    private(set) var rowHeight: CGFloat
    private var tabWidth = EditorSettings.tabWidth
    private var syntaxHighlighting = EditorSettings.syntaxHighlighting
    private var highlighters: [SyntaxHighlighter?] = []
    let panes: [DiffPane]

    @Published private(set) var hunks: [DiffHunk] = []
    @Published private(set) var rowCount = 0
    @Published private(set) var currentHunk: Int?
    /// Rows visible in the panes, for the location pane.
    @Published private(set) var visibleRows: Range<Int> = 0..<0
    @Published private(set) var info: [PaneInfo]
    @Published private(set) var loadError: String?
    @Published private(set) var statusMessage: String?
    /// Two-way only: line pairs the user has forced onto the same row.
    @Published private(set) var syncPoints: [(left: Int, right: Int)] = []
    /// Wrap long lines to the pane width instead of scrolling sideways.
    @Published var wrapLines = UserDefaults.standard.bool(forKey: "editor.wrapLines") {
        didSet {
            guard wrapLines != oldValue else { return }
            UserDefaults.standard.set(wrapLines, forKey: "editor.wrapLines")
            for pane in panes { pane.setWrapping(wrapLines) }
            refreshLayout(syntax: false)
        }
    }
    /// Merge mode (F9): plain arrow keys move between differences and copy them.
    @Published var mergeMode = false
    @Published var showsInlineDifferences = true {
        didSet { redraw() }
    }
    /// Show only this many unchanged lines around each difference; nil shows every line.
    @Published var diffContext: Int? = DiffContextSetting.stored {
        didSet {
            guard diffContext != oldValue else { return }
            DiffContextSetting.stored = diffContext
            if diffContext != nil { DiffContextSetting.lastNumber = diffContext! }
            recomputeNow()
            if let c = currentHunk { select(hunk: c) }
        }
    }

    private(set) var rows: [AlignedRow] = []
    /// Rows on screen, top to bottom (all rows unless unchanged lines are folded away).
    private(set) var shownRows: [Int] = []
    /// For each row, its position among the shown rows (a hidden row gets the next shown row's position).
    private var displayIndex: [Int] = []
    /// Two-way only: lines that moved, per pane.
    private(set) var moved: [[Int: Int]] = [[:], [:]]
    private var lines: [[String]]
    private var lineStarts: [[Int]]
    private var lineToRow: [[Int]]
    /// Height of the filler rows above each pane's first line.
    private var leadingHeight: [CGFloat]
    /// Height of every row: one text line, more when a line wraps, 0 when folded away.
    private(set) var rowHeights: [CGFloat] = []
    /// Top of each shown row measured from row 0, with the total height as the last element.
    private(set) var shownTops: [CGFloat] = [0]
    /// How many screen lines each text line takes in each pane (1 unless wrapped).
    private var fragmentCounts: [[Int]] = []
    private var hiddenRowFlags: [Bool] = []
    private var lastWidths: [CGFloat] = []
    private var pendingRelayout: DispatchWorkItem?
    private var inlineCache: [Int: [[NSRange]]] = [:]
    private var pendingRecompute: DispatchWorkItem?
    private var isSyncingScroll = false
    private var isMovingCaret = false
    private(set) var activePane = 0
    private var closeGuard: WindowCloseGuard?
    private var watchers: [FileWatcher] = []
    private(set) var options = CompareSettings.options

    weak var window: NSWindow? {
        didSet {
            guard let window, window !== oldValue else { return }
            closeGuard = WindowCloseGuard(window: window) { [weak self] in self?.confirmClose() ?? true }
            updateDocumentEdited()
            // While the window is first laid out, AppKit can leave a pane scrolled sideways
            // under the line-number ruler; start every pane at its left edge.
            DispatchQueue.main.async { [weak self] in self?.resetHorizontalScroll() }
        }
    }

    init(target: CompareTarget) {
        self.target = target
        let count = target.isThreeWay ? 3 : 2
        let font = self.font
        rowHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        panes = (0..<count).map { DiffPane(index: $0, font: font) }
        lines = Array(repeating: [], count: count)
        lineStarts = Array(repeating: [], count: count)
        lineToRow = Array(repeating: [], count: count)
        leadingHeight = Array(repeating: 0, count: count)
        info = Self.initialInfo(target)
        super.init()
        highlighters = info.map { SyntaxHighlighter.forFile($0.url ?? target.left) }
        for pane in panes {
            pane.textView.controller = self
            pane.textView.delegate = self
            pane.setWrapping(wrapLines)
            pane.textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(paneResized(_:)), name: NSView.frameDidChangeNotification, object: pane.textView)
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewScrolled(_:)), name: NSView.boundsDidChangeNotification, object: pane.scrollView.contentView)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        load()
        if target.kind != .conflict {
            watchers = (0..<count).compactMap { p in
                info[p].url.map { url in FileWatcher(url: url) { [weak self] in self?.fileChangedOnDisk(pane: p) } }
            }
        }
        DebugActions.runIfRequested(on: self)
    }

    private static func initialInfo(_ t: CompareTarget) -> [PaneInfo] {
        switch t.kind {
        case .conflict:
            return [PaneInfo(url: nil, title: L("My Changes"), file: .empty),
                    PaneInfo(url: t.left, title: t.left.path(percentEncoded: false), file: .empty),
                    PaneInfo(url: nil, title: L("Their Changes"), file: .empty)]
        default:
            var list = [PaneInfo(url: t.left, title: t.left.path(percentEncoded: false), file: .empty)]
            if let middle = t.middle {
                let saveTo = t.output ?? middle
                var title = middle.path(percentEncoded: false)
                if saveTo != middle { title += L(" (saves to \(saveTo.lastPathComponent))") }
                list.append(PaneInfo(url: saveTo, title: title, file: .empty))
            }
            list.append(PaneInfo(url: t.right, title: t.right.path(percentEncoded: false), file: .empty))
            return list
        }
    }

    var paneCount: Int { panes.count }
    var isThreeWay: Bool { paneCount == 3 }
    var isBinary: Bool { info.contains { $0.file.isBinary } }
    var binaryFilesIdentical: Bool {
        let urls = [target.left, target.right] + (target.middle.map { [$0] } ?? [])
        let data = urls.map { try? Data(contentsOf: $0) }
        return data.allSatisfy { $0 == data[0] }
    }

    func pane(_ index: Int) -> DiffPane { panes[index] }

    /// The line shown in `pane` on `row`, or nil for a filler row.
    func line(_ row: AlignedRow, pane: Int) -> Int? { row.line(pane: pane, of: paneCount) }

    // MARK: Loading and diffing

    func load() {
        var texts: [TextFile] = []
        do {
            switch target.kind {
            case .conflict:
                let file = try TextFile.load(target.left)
                guard let conflict = ConflictFile(text: file.text) else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "No conflict markers (<<<<<<< and >>>>>>>) were found."])
                }
                var ours = file, base = file, theirs = file
                ours.text = conflict.ours; base.text = conflict.base; theirs.text = conflict.theirs
                texts = [ours, base, theirs]
                if !conflict.oursLabel.isEmpty { info[0].title = L("My Changes (\(conflict.oursLabel))") }
                if !conflict.theirsLabel.isEmpty { info[2].title = L("Their Changes (\(conflict.theirsLabel))") }
                statusMessage = L("Loaded \(conflict.conflictCount) conflict markers. The middle pane is the result that gets saved.")
            default:
                var urls = [target.left, target.right]
                if let middle = target.middle { urls.insert(middle, at: 1) }
                texts = try urls.map(TextFile.load)
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            texts = Array(repeating: .empty, count: paneCount)
        }
        for i in 0..<paneCount {
            info[i].file = texts[i]
            info[i].isDirty = false
            let tv = panes[i].textView
            let attrs = baseAttributes(spacing: 0)
            tv.textStorage?.setAttributedString(NSAttributedString(string: texts[i].text, attributes: attrs))
            tv.typingAttributes = attrs
            tv.undoManager?.removeAllActions(withTarget: tv.textStorage as Any)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
        activePane = isThreeWay ? 1 : 0
        currentHunk = nil
        recomputeNow()
        updateDocumentEdited()
        if !hunks.isEmpty { select(hunk: 0) }
    }

    func recomputeNow() {
        pendingRecompute?.cancel()
        pendingRecompute = nil
        let texts = panes.map { $0.textView.string }
        lines = texts.map(splitLines)
        lineStarts = texts.map(Self.lineStarts)
        if isThreeWay {
            let comparison = ThreeWayComparison(left: lines[0], middle: lines[1], right: lines[2], options: options)
            rows = comparison.rows
            hunks = comparison.hunks
            moved = [[:], [:], [:]]
        } else {
            let comparison = LineComparison(left: lines[0], right: lines[1], options: options, syncPoints: syncPoints)
            rows = comparison.rows
            hunks = comparison.hunks
            moved = [comparison.movedLeft, comparison.movedRight]
        }
        inlineCache = [:]

        lineToRow = lines.map { Array(repeating: 0, count: $0.count) }
        for (r, row) in rows.enumerated() {
            for p in 0..<paneCount {
                if let l = line(row, pane: p), l < lineToRow[p].count { lineToRow[p][l] = r }
            }
        }
        rowCount = rows.count
        if let c = currentHunk, c >= hunks.count { currentHunk = hunks.isEmpty ? nil : hunks.count - 1 }
        refreshLayout(syntax: true)
    }

    /// Recomputes folding, row heights and the spacing that keeps the panes aligned.
    private func refreshLayout(syntax: Bool) {
        pendingRelayout?.cancel()
        pendingRelayout = nil
        updateFolding()
        if syntax { for p in 0..<paneCount { applySyntax(pane: p) } }
        measureRows()
        for p in 0..<paneCount { applyLayout(pane: p) }
        lastWidths = panes.map { $0.textView.frame.width }
        updateVisibleRows()
        redraw()
    }

    /// Works out every row's height. Without wrapping each row is one line tall; with
    /// wrapping a row is as tall as its longest wrapped line in any pane.
    private func measureRows() {
        fragmentCounts = lines.map { Array(repeating: 1, count: $0.count) }
        if wrapLines {
            for p in 0..<paneCount {
                guard let lm = panes[p].textView.layoutManager, let container = panes[p].textView.textContainer else { continue }
                var counts = Array(repeating: 0, count: lines[p].count)
                lm.ensureLayout(for: container)
                let starts = lineStarts[p]
                var l = 0
                lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: container)) { _, _, _, glyphRange, _ in
                    let c = lm.characterIndexForGlyph(at: glyphRange.location)
                    while l + 1 < starts.count, starts[l + 1] <= c { l += 1 }
                    if l < counts.count { counts[l] += 1 }
                }
                fragmentCounts[p] = counts.map { max($0, 1) }
            }
        }
        rowHeights = rows.indices.map { r in
            if hiddenRowFlags.indices.contains(r), hiddenRowFlags[r] { return 0 }
            let tallest = (0..<paneCount).compactMap { p in line(rows[r], pane: p).map { $0 < fragmentCounts[p].count ? fragmentCounts[p][$0] : 1 } }.max() ?? 1
            return CGFloat(tallest) * rowHeight
        }
        var tops: [CGFloat] = [0]
        tops.reserveCapacity(shownRows.count + 1)
        for r in shownRows { tops.append(tops[tops.count - 1] + rowHeights[r]) }
        shownTops = tops
    }

    @objc private func paneResized(_ note: Notification) {
        guard wrapLines, let tv = note.object as? DiffTextView, lastWidths.indices.contains(tv.paneIndex),
              abs(tv.frame.width - lastWidths[tv.paneIndex]) > 0.5 else { return }
        pendingRelayout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshLayout(syntax: false) }
        pendingRelayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Works out which rows to hide for the diff context setting and tells each pane.
    private func updateFolding() {
        var hiddenRow = Array(repeating: false, count: rows.count)
        if let context = diffContext {
            var near = Array(repeating: false, count: rows.count)
            for hunk in hunks {
                let lo = max(0, hunk.rows.lowerBound - context), hi = min(rows.count, hunk.rows.upperBound + context)
                for r in lo..<hi { near[r] = true }
            }
            for (r, row) in rows.enumerated() where !near[r] {
                // Only rows with a line on every side can be hidden; filler rows must stay.
                hiddenRow[r] = (0..<paneCount).allSatisfy { line(row, pane: $0) != nil }
            }
        }
        hiddenRowFlags = hiddenRow
        shownRows = rows.indices.filter { !hiddenRow[$0] }
        displayIndex = Array(repeating: 0, count: rows.count)
        var next = shownRows.count
        for r in stride(from: rows.count - 1, through: 0, by: -1) {
            if !hiddenRow[r] { next -= 1 }
            displayIndex[r] = next
        }
        for p in 0..<paneCount {
            var hiddenLine = Array(repeating: false, count: lines[p].count)
            for (r, row) in rows.enumerated() where hiddenRow[r] {
                if let l = line(row, pane: p), l < hiddenLine.count { hiddenLine[l] = true }
            }
            let pane = panes[p]
            pane.hiddenLines.rowHeight = rowHeight
            if pane.hiddenLines.update(lineStarts: lineStarts[p], hidden: hiddenLine), let lm = pane.textView.layoutManager {
                let full = NSRange(location: 0, length: pane.textView.textStorage?.length ?? 0)
                lm.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
                lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            }
        }
    }

    private func scheduleRecompute() {
        pendingRecompute?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recomputeNow() }
        pendingRecompute = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func recomputeIfPending() {
        if pendingRecompute != nil { recomputeNow() }
    }

    private static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        return starts
    }

    private func baseAttributes(spacing: CGFloat) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = rowHeight
        style.maximumLineHeight = rowHeight
        style.paragraphSpacing = spacing
        style.tabStops = []
        style.defaultTabInterval = CGFloat(tabWidth) * (" " as NSString).size(withAttributes: [.font: font]).width
        return [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: style]
    }

    /// Colors keywords, strings and comments. Skipped for very large files to keep typing fast.
    private func applySyntax(pane p: Int) {
        guard let storage = panes[p].textView.textStorage else { return }
        storage.beginEditing()
        if syntaxHighlighting, storage.length < 1_000_000, let highlighter = highlighters[p] {
            highlighter.apply(to: storage)
        } else {
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(location: 0, length: storage.length))
        }
        storage.endEditing()
    }

    /// Picks up font, tab width and syntax setting changes.
    private func applyEditorSettings() -> Bool {
        let newFont = EditorSettings.font, newTab = EditorSettings.tabWidth, newSyntax = EditorSettings.syntaxHighlighting
        guard newFont != font || newTab != tabWidth || newSyntax != syntaxHighlighting else { return false }
        font = newFont
        tabWidth = newTab
        syntaxHighlighting = newSyntax
        rowHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        for pane in panes {
            guard let storage = pane.textView.textStorage else { continue }
            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            pane.textView.font = font
        }
        return true
    }

    /// Adds paragraph spacing under lines that are followed by filler rows, so all panes line up.
    private func applyLayout(pane p: Int) {
        let tv = panes[p].textView
        guard let storage = tv.textStorage else { return }

        // Space under a line = the extra height of its row (when another pane's line wraps
        // further) plus the filler rows that follow it on this pane.
        var leading: CGFloat = 0
        var spacingAfter: [Int: CGFloat] = [:]
        var lastLine: Int?
        var pending: CGFloat = 0
        for (r, row) in rows.enumerated() {
            if let l = line(row, pane: p) {
                if pending > 0 {
                    if let lastLine { spacingAfter[lastLine, default: 0] += pending } else { leading += pending }
                }
                lastLine = l
                let own = hiddenRowFlags[r] ? 0 : CGFloat(l < fragmentCounts[p].count ? fragmentCounts[p][l] : 1) * rowHeight
                pending = max(0, rowHeights[r] - own)
            } else {
                pending += rowHeights[r]
            }
        }
        leadingHeight[p] = leading

        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.paragraphStyle, value: baseAttributes(spacing: 0)[.paragraphStyle]!, range: full)
        for (l, spacing) in spacingAfter where spacing > 0 {
            guard l + 1 < lineStarts[p].count else { continue }
            let start = lineStarts[p][l]
            let range = NSRange(location: start, length: lineStarts[p][l + 1] - start)
            guard NSMaxRange(range) <= storage.length else { continue }
            storage.addAttribute(.paragraphStyle, value: baseAttributes(spacing: spacing)[.paragraphStyle]!, range: range)
        }
        storage.endEditing()
        tv.typingAttributes = baseAttributes(spacing: 0)
        tv.textContainerInset = NSSize(width: 4, height: leading)

        let height = (shownTops.last ?? 0) + (leadingHeight.max() ?? 0) + 40
        tv.minSize = NSSize(width: 0, height: height)
        tv.sizeToFit()
    }

    func redraw() {
        for pane in panes {
            pane.textView.needsDisplay = true
            pane.scrollView.verticalRulerView?.needsDisplay = true
        }
    }

    // MARK: Geometry and colors used by drawing

    /// The y position of row 0 in the text view's coordinates.
    func rowOriginY(in textView: NSTextView, pane: Int) -> CGFloat {
        textView.textContainerOrigin.y - leadingHeight[pane]
    }

    /// The shown row at a vertical offset from row 0.
    func displayRow(atOffset y: CGFloat) -> Int {
        guard shownTops.count > 1 else { return 0 }
        var lo = 0, hi = shownTops.count - 2
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if shownTops[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func lineStart(pane: Int, line: Int) -> Int? {
        let starts = lineStarts[pane]
        return line < starts.count ? starts[line] : nil
    }

    /// The background of `row` in `pane`, or nil for none.
    func background(row r: Int, pane p: Int) -> NSColor? {
        let row = rows[r]
        let hasLine = line(row, pane: p) != nil
        guard let h = row.hunk, hunks.indices.contains(h) else {
            guard row.isIgnored else { return nil }
            return hasLine ? DiffColors.ignored : DiffColors.ignoredGhost
        }
        let isCurrent = h == currentHunk
        if !hasLine { return isCurrent ? DiffColors.selectedGhost : DiffColors.ghost }
        if let l = line(row, pane: p), moved.indices.contains(p), moved[p][l] != nil {
            return isCurrent ? DiffColors.selectedMoved : DiffColors.moved
        }
        if hunks[h].kind == .conflict || hunks[h].kind == .change {
            return isCurrent ? DiffColors.selected : DiffColors.changed
        }
        // Three-way changes that can be merged automatically.
        return isCurrent ? DiffColors.selectedMergeable : DiffColors.mergeable
    }

    func inlineColor(row r: Int) -> NSColor {
        let isCurrent = rows[r].hunk == currentHunk
        if let h = rows[r].hunk, hunks.indices.contains(h), hunks[h].kind != .change, hunks[h].kind != .conflict {
            return isCurrent ? DiffColors.selectedMergeableWord : DiffColors.mergeableWord
        }
        return isCurrent ? DiffColors.selectedWord : DiffColors.word
    }

    func inlineRanges(row r: Int, pane p: Int) -> [NSRange] {
        if inlineCache[r] == nil { inlineCache[r] = computeInline(row: r) }
        return inlineCache[r]?[p] ?? []
    }

    private func computeInline(row r: Int) -> [[NSRange]] {
        var result = Array(repeating: [NSRange](), count: paneCount)
        let row = rows[r]
        guard let h = row.hunk, hunks.indices.contains(h) else { return result }
        func text(_ p: Int) -> String? {
            guard let l = line(row, pane: p), l < lines[p].count, lines[p][l].utf16.count < 5000 else { return nil }
            return lines[p][l]
        }
        if !isThreeWay {
            if let a = text(0), let b = text(1) {
                let d = inlineDifferences(a, b, options: options)
                result = [d.left, d.right]
            }
            return result
        }
        // Three-way: each side is compared with the base; the base with the side that changed it.
        guard let base = text(1) else { return result }
        if let a = text(0) { result[0] = inlineDifferences(a, base, options: options).left }
        if let b = text(2) { result[2] = inlineDifferences(b, base, options: options).left }
        let kind = hunks[h].kind
        if let other = kind == .rightOnly ? text(2) : text(0) {
            result[1] = inlineDifferences(base, other, options: options).left
        }
        return result
    }

    @objc private func defaultsChanged() {
        let new = CompareSettings.options
        let editorChanged = applyEditorSettings()
        if new != options {
            options = new
            currentHunk = nil
            recomputeNow()
        } else if editorChanged {
            recomputeNow()
        } else {
            redraw() // colors may have changed
        }
    }

    // MARK: Scrolling

    @objc private func clipViewScrolled(_ note: Notification) {
        guard !isSyncingScroll, let source = note.object as? NSClipView else { return }
        isSyncingScroll = true
        for pane in panes where pane.scrollView.contentView !== source {
            let clip = pane.scrollView.contentView
            let origin = clip.constrainBoundsRect(NSRect(origin: source.bounds.origin, size: clip.bounds.size)).origin
            clip.setBoundsOrigin(origin)
            pane.scrollView.reflectScrolledClipView(clip)
        }
        isSyncingScroll = false
        updateVisibleRows()
    }

    func resetHorizontalScroll() {
        isSyncingScroll = true
        for pane in panes {
            let clip = pane.scrollView.contentView
            clip.setBoundsOrigin(NSPoint(x: -clip.contentInsets.left, y: clip.bounds.minY))
            pane.scrollView.reflectScrolledClipView(clip)
        }
        isSyncingScroll = false
    }

    private func updateVisibleRows() {
        let tv = panes[0].textView
        let visible = panes[0].scrollView.contentView.bounds
        let top = rowOriginY(in: tv, pane: 0)
        guard !shownRows.isEmpty else { visibleRows = 0..<0; return }
        let first = displayRow(atOffset: visible.minY - top)
        let last = displayRow(atOffset: visible.maxY - top)
        let range = shownRows[first]..<(shownRows[last] + 1)
        if range != visibleRows { visibleRows = range }
    }

    /// Scrolls so that `row` sits about a third of the way down the panes.
    func scrollToRow(_ row: Int, centered: Bool = true) {
        let tv = panes[0].textView
        let clip = panes[0].scrollView.contentView
        let shown = displayIndex.indices.contains(row) ? min(displayIndex[row], shownTops.count - 1) : 0
        let y = rowOriginY(in: tv, pane: 0) + shownTops[max(shown, 0)]
        let offset = centered ? clip.bounds.height / 3 : 0
        let origin = clip.constrainBoundsRect(NSRect(x: clip.bounds.minX, y: y - offset, width: clip.bounds.width, height: clip.bounds.height)).origin
        clip.setBoundsOrigin(origin)
        panes[0].scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Selection and navigation

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? DiffTextView, !isMovingCaret, pendingRecompute == nil else { return }
        activePane = tv.paneIndex
        let row = caretRow(pane: tv.paneIndex)
        if let hunk = rows.indices.contains(row) ? rows[row].hunk : nil, hunk != currentHunk {
            currentHunk = hunk
            redraw()
        }
    }

    func textDidBeginEditing(_ notification: Notification) {
        if let tv = notification.object as? DiffTextView { activePane = tv.paneIndex }
    }

    private func caretRow(pane p: Int) -> Int {
        let location = panes[p].textView.selectedRange().location
        let starts = lineStarts[p]
        guard !starts.isEmpty else { return 0 }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo < lineToRow[p].count ? lineToRow[p][lo] : 0
    }

    func nextDifference(conflictsOnly: Bool = false) {
        recomputeIfPending()
        let from = currentHunk.map { hunks[$0].rows.upperBound } ?? caretRow(pane: activePane)
        let start = currentHunk.map { $0 + 1 } ?? 0
        if let i = hunks.indices.dropFirst(start).first(where: { hunks[$0].rows.lowerBound >= from && (!conflictsOnly || hunks[$0].kind == .conflict) }) {
            select(hunk: i)
        }
    }

    func previousDifference(conflictsOnly: Bool = false) {
        recomputeIfPending()
        let before = currentHunk.map { hunks[$0].rows.lowerBound } ?? caretRow(pane: activePane)
        if let i = hunks.indices.last(where: { hunks[$0].rows.upperBound <= before && (!conflictsOnly || hunks[$0].kind == .conflict) }) {
            select(hunk: i)
        }
    }

    func firstDifference() { if !hunks.isEmpty { select(hunk: 0) } }
    func lastDifference() { if !hunks.isEmpty { select(hunk: hunks.count - 1) } }
    func currentDifference() { if let c = currentHunk { select(hunk: c) } }

    var conflictCount: Int { hunks.filter { $0.kind == .conflict }.count }

    func select(hunk index: Int) {
        guard hunks.indices.contains(index) else { return }
        currentHunk = index
        let hunk = hunks[index]
        // Put the caret at the start of the difference in the pane being worked in.
        let range = hunk.range(pane: activePane, of: paneCount)
        let l = min(range.lowerBound, max(0, lineStarts[activePane].count - 1))
        if let start = lineStart(pane: activePane, line: l) {
            isMovingCaret = true
            panes[activePane].textView.setSelectedRange(NSRange(location: start, length: 0))
            isMovingCaret = false
        }
        scrollToRow(hunk.rows.lowerBound)
        redraw()
    }

    /// Jumps to the row at `fraction` (0...1) of the whole comparison, for the location pane.
    func scrollToFraction(_ fraction: CGFloat) {
        guard !rows.isEmpty else { return }
        let row = Int(CGFloat(rows.count) * min(max(fraction, 0), 1))
        scrollToRow(row, centered: true)
    }

    // MARK: Copying differences

    /// Panes for "copy rightward": two-way left → right, three-way left → middle.
    var rightwardPanes: (from: Int, to: Int) { (0, 1) }
    /// Panes for "copy leftward": two-way right → left, three-way right → middle.
    var leftwardPanes: (from: Int, to: Int) { isThreeWay ? (2, 1) : (1, 0) }

    func copyCurrent(from src: Int, to dst: Int, advance: Bool = false) {
        recomputeIfPending()
        guard let index = currentHunk, hunks.indices.contains(index) else { return }
        let undo = panes[dst].textView.undoManager
        undo?.beginUndoGrouping()
        apply(hunks[index], from: src, to: dst)
        undo?.endUndoGrouping()
        undo?.setActionName(L("Copy Difference"))
        recomputeNow()
        if advance, !hunks.isEmpty {
            select(hunk: min(index, hunks.count - 1))
        } else {
            currentHunk = nil
            redraw()
        }
    }

    func copyRightward(advance: Bool = false) { copyCurrent(from: rightwardPanes.from, to: rightwardPanes.to, advance: advance) }
    func copyLeftward(advance: Bool = false) { copyCurrent(from: leftwardPanes.from, to: leftwardPanes.to, advance: advance) }

    func copyAll(from src: Int, to dst: Int) {
        recomputeIfPending()
        guard !hunks.isEmpty else { return }
        let undo = panes[dst].textView.undoManager
        undo?.beginUndoGrouping()
        // Work from the bottom up so earlier line numbers stay valid.
        for hunk in hunks.reversed() { apply(hunk, from: src, to: dst) }
        undo?.endUndoGrouping()
        undo?.setActionName(L("Copy All"))
        currentHunk = nil
        recomputeNow()
    }

    /// Three-way: takes every change made on only one side (or the same on both) into the middle.
    /// Conflicts are left for the user.
    func autoMerge() {
        guard isThreeWay else { return }
        recomputeIfPending()
        let mergeable = hunks.filter { $0.kind != .conflict }
        guard !mergeable.isEmpty else {
            statusMessage = L("There are no differences that can be merged automatically")
            return
        }
        let undo = panes[1].textView.undoManager
        undo?.beginUndoGrouping()
        for hunk in mergeable.reversed() {
            apply(hunk, from: hunk.kind == .rightOnly ? 2 : 0, to: 1)
        }
        undo?.endUndoGrouping()
        undo?.setActionName(L("Auto Merge"))
        currentHunk = nil
        recomputeNow()
        let left = conflictCount
        statusMessage = left > 0
            ? L("Merged \(mergeable.count) differences automatically. \(left) conflicts remain.")
            : L("Merged \(mergeable.count) differences automatically.")
        if left > 0, let first = hunks.firstIndex(where: { $0.kind == .conflict }) { select(hunk: first) }
    }

    private func apply(_ hunk: DiffHunk, from src: Int, to dst: Int) {
        let newLines = Array(lines[src][hunk.range(pane: src, of: paneCount)])
        replaceLines(pane: dst, range: hunk.range(pane: dst, of: paneCount), with: newLines)
    }

    /// Replaces whole lines through the text view so the change can be undone.
    private func replaceLines(pane p: Int, range: Range<Int>, with newLines: [String]) {
        let tv = panes[p].textView
        let starts = lineStarts[p]
        let current = lines[p]
        let n = current.count
        let end = { (line: Int) in starts[line] + (current[line] as NSString).length }

        var charRange: NSRange
        var replacement: String
        if !range.isEmpty, !newLines.isEmpty {
            charRange = NSRange(location: starts[range.lowerBound], length: end(range.upperBound - 1) - starts[range.lowerBound])
            replacement = newLines.joined(separator: "\n")
        } else if !range.isEmpty {
            if range.upperBound < n {
                charRange = NSRange(location: starts[range.lowerBound], length: starts[range.upperBound] - starts[range.lowerBound])
            } else if range.lowerBound > 0 {
                charRange = NSRange(location: end(range.lowerBound - 1), length: end(n - 1) - end(range.lowerBound - 1))
            } else {
                charRange = NSRange(location: 0, length: (tv.string as NSString).length)
            }
            replacement = ""
        } else if !newLines.isEmpty {
            if range.lowerBound < n {
                charRange = NSRange(location: starts[range.lowerBound], length: 0)
                replacement = newLines.joined(separator: "\n") + "\n"
            } else {
                charRange = NSRange(location: end(n - 1), length: 0)
                replacement = "\n" + newLines.joined(separator: "\n")
            }
        } else {
            return
        }

        guard tv.shouldChangeText(in: charRange, replacementString: replacement) else { return }
        tv.textStorage?.replaceCharacters(in: charRange, with: NSAttributedString(string: replacement, attributes: baseAttributes(spacing: 0)))
        tv.didChangeText()
    }

    /// Reloads a pane whose file another app changed, unless it has unsaved edits.
    private func fileChangedOnDisk(pane p: Int) {
        guard let url = info[p].url, let file = try? TextFile.load(url), file.exists, !file.isBinary else { return }
        guard file.text != panes[p].textView.string else { return } // e.g. our own save
        let name = url.lastPathComponent
        if info[p].isDirty {
            statusMessage = L("\(name) was changed by another app. Your unsaved edits were kept.")
            return
        }
        info[p].file = file
        let tv = panes[p].textView
        tv.textStorage?.setAttributedString(NSAttributedString(string: file.text, attributes: baseAttributes(spacing: 0)))
        tv.undoManager?.removeAllActions()
        currentHunk = nil
        recomputeNow()
        statusMessage = L("Reloaded \(name) because it was changed by another app.")
    }

    // MARK: Editing tools

    /// Moves the caret to a 1-based line in the active pane.
    func goToLine(_ number: Int) {
        let p = activePane
        let l = min(max(number - 1, 0), max(lineStarts[p].count - 1, 0))
        guard let start = lineStart(pane: p, line: l) else { return }
        panes[p].textView.setSelectedRange(NSRange(location: start, length: 0))
        panes[p].textView.window?.makeFirstResponder(panes[p].textView)
        if l < lineToRow[p].count { scrollToRow(lineToRow[p][l]) }
    }

    /// Asks for a line number and goes there.
    func promptGoToLine() {
        let alert = NSAlert()
        alert.messageText = L("Go to Line")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = L("Line number")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Go"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        goToLine(number)
    }

    func caretLine(pane p: Int) -> Int {
        let location = panes[p].textView.selectedRange().location
        let starts = lineStarts[p]
        var lo = 0, hi = max(starts.count - 1, 0)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func toggleBookmark() {
        let l = caretLine(pane: activePane)
        if info[activePane].bookmarks.contains(l) { info[activePane].bookmarks.remove(l) } else { info[activePane].bookmarks.insert(l) }
        redraw()
    }

    func nextBookmark(forward: Bool = true) {
        let marks = info[activePane].bookmarks.sorted()
        guard !marks.isEmpty else { return }
        let l = caretLine(pane: activePane)
        let target = forward ? (marks.first { $0 > l } ?? marks[0]) : (marks.last { $0 < l } ?? marks[marks.count - 1])
        goToLine(target + 1)
    }

    func clearBookmarks() {
        for p in 0..<paneCount { info[p].bookmarks = [] }
        redraw()
    }

    /// Makes the lines under the left and right carets line up (WinMerge's synchronization point).
    func addSyncPoint() {
        guard !isThreeWay else { return }
        recomputeIfPending()
        let point = (left: caretLine(pane: 0), right: caretLine(pane: 1))
        // Drop points that would cross the new one.
        syncPoints.removeAll { ($0.left <= point.left) != ($0.right <= point.right) || $0.left == point.left || $0.right == point.right }
        syncPoints.append(point)
        syncPoints.sort { $0.left < $1.left }
        currentHunk = nil
        recomputeNow()
        statusMessage = L("Synchronization point added at left line \(point.left + 1) and right line \(point.right + 1).")
    }

    func clearSyncPoints() {
        syncPoints = []
        recomputeNow()
    }

    func isSyncLine(_ line: Int, pane p: Int) -> Bool {
        !isThreeWay && syncPoints.contains { (p == 0 ? $0.left : $0.right) == line }
    }

    func setReadOnly(_ readOnly: Bool, pane p: Int) {
        info[p].isReadOnly = readOnly
        panes[p].textView.isEditable = !readOnly
    }

    /// Swaps the left and right panes, keeping unsaved edits.
    func swapSides() {
        recomputeIfPending()
        let a = 0, b = paneCount - 1
        let texts = [panes[a].textView.string, panes[b].textView.string]
        info.swapAt(a, b)
        highlighters.swapAt(a, b)
        for (p, text) in [(a, texts[1]), (b, texts[0])] {
            let tv = panes[p].textView
            tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes(spacing: 0)))
            tv.undoManager?.removeAllActions()
            tv.isEditable = !info[p].isReadOnly
        }
        currentHunk = nil
        recomputeNow()
        updateDocumentEdited()
    }

    /// Changes the line ending used when the pane is saved.
    func setLineEnding(_ ending: LineEnding, pane p: Int) {
        guard info[p].file.lineEnding != ending else { return }
        info[p].file.lineEnding = ending
        info[p].isDirty = info[p].url != nil
        updateDocumentEdited()
    }

    /// Changes the encoding used when the pane is saved.
    func setEncoding(_ encoding: String.Encoding, bom: Bool, pane p: Int) {
        guard info[p].file.encoding != encoding || info[p].file.hasBOM != bom else { return }
        info[p].file.encoding = encoding
        info[p].file.hasBOM = bom
        info[p].isDirty = info[p].url != nil
        updateDocumentEdited()
    }

    /// Reads the pane's file again, decoding it with `encoding`.
    func reopen(pane p: Int, as encoding: String.Encoding) {
        guard let url = info[p].url ?? (p == 0 ? target.left : target.right) as URL? else { return }
        if info[p].isDirty, !confirmDiscard(message: L("Reloading discards unsaved changes.")) { return }
        guard let data = try? Data(contentsOf: url), let file = TextFile.decode(data, as: encoding) else {
            let alert = NSAlert()
            alert.messageText = L("The file cannot be read with this encoding")
            alert.runModal()
            return
        }
        info[p].file = file
        info[p].isDirty = false
        let tv = panes[p].textView
        tv.textStorage?.setAttributedString(NSAttributedString(string: file.text, attributes: baseAttributes(spacing: 0)))
        tv.undoManager?.removeAllActions()
        recomputeNow()
        updateDocumentEdited()
    }

    /// Opens the pane's file in another app: the default one, or one the user picks.
    func openExternally(pane p: Int, choosingApp: Bool) {
        guard let url = info[p].url, FileManager.default.fileExists(atPath: url.path) else { return }
        guard choosingApp else {
            NSWorkspace.shared.open(url)
            return
        }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = L("Choose an app to open the file with")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Patch and report

    /// A unified patch from the left pane to the right pane (two-way only).
    func makePatch() -> String {
        UnifiedDiff.make(oldName: target.left.path(percentEncoded: false), newName: target.right.path(percentEncoded: false),
                         oldText: panes[0].textView.string, newText: panes[1].textView.string)
    }

    /// An HTML report of the left and right panes.
    func makeReport() -> String {
        let last = paneCount - 1
        let comparison = LineComparison(left: lines[0], right: lines[last], options: options)
        return HTMLReport.fileComparison(leftTitle: info[0].title, rightTitle: info[last].title,
                                         left: lines[0], right: lines[last], comparison: comparison, options: options)
    }

    // MARK: Editing and saving

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? DiffTextView else { return }
        if !info[tv.paneIndex].isDirty {
            info[tv.paneIndex].isDirty = true
            updateDocumentEdited()
        }
        scheduleRecompute()
    }

    /// True when a pane that can be saved has unsaved changes.
    var isDirty: Bool { info.contains { $0.isDirty && $0.url != nil } }

    @discardableResult
    func save(pane p: Int) -> Bool {
        guard let url = info[p].url else { return true }
        var file = info[p].file
        let text = panes[p].textView.string
        var data = file.encode(text)
        if data == nil {
            let alert = NSAlert()
            alert.messageText = L("The text contains characters that cannot be saved in \(file.encodingName)")
            alert.informativeText = L("Save it as UTF-8?")
            alert.addButton(withTitle: L("Save as UTF-8"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            file.encoding = .utf8
            file.hasBOM = false
            data = file.encode(text)
        }
        do {
            try data!.write(to: url, options: .atomic)
            file.text = text
            file.exists = true
            info[p].file = file
            info[p].isDirty = false
            updateDocumentEdited()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    func saveAll() {
        if target.kind == .conflict, conflictCount > 0 {
            let alert = NSAlert()
            alert.messageText = L("\(conflictCount) conflicts are still unresolved")
            alert.informativeText = L("If you save now, the unresolved parts keep the contents of the middle pane (which may be empty).")
            alert.addButton(withTitle: L("Save"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for p in 0..<paneCount where info[p].isDirty { save(pane: p) }
    }

    func reload() {
        guard confirmDiscard(message: L("Reloading discards unsaved changes.")) else { return }
        load()
    }

    private func updateDocumentEdited() {
        window?.isDocumentEdited = isDirty
    }

    private func confirmDiscard(message: String) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("There are unsaved changes")
        alert.informativeText = message
        alert.addButton(withTitle: L("Continue"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks what to do with unsaved changes before the window closes.
    private func confirmClose() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("Do you want to save the changes?")
        alert.informativeText = L("Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Don’t Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveAll()
            return !isDirty
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }
}

/// The remembered diff context choice (nil = show all lines).
enum DiffContextSetting {
    static var stored: Int? {
        get { UserDefaults.standard.object(forKey: "view.diffContext") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "view.diffContext") }
    }
    /// The number of lines ⌘D switches to.
    static var lastNumber: Int {
        get { UserDefaults.standard.object(forKey: "view.diffContextLast") as? Int ?? 3 }
        set { UserDefaults.standard.set(newValue, forKey: "view.diffContextLast") }
    }
}

/// Lets the controller veto closing a SwiftUI-managed window. It wraps the window's
/// existing delegate and forwards everything else to it.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let shouldClose: () -> Bool

    init(window: NSWindow, shouldClose: @escaping () -> Bool) {
        original = window.delegate
        self.shouldClose = shouldClose
        super.init()
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

/// For development: `MACMERGE_ACTIONS=next,copyRight,undo,save` runs menu actions on the first
/// file comparison shortly after it opens, so behaviour can be checked from scripts.
@MainActor
enum DebugActions {
    private static var didRun = false

    static func runIfRequested(on c: FileCompareController) {
        guard !didRun, let list = ProcessInfo.processInfo.environment["MACMERGE_ACTIONS"] else { return }
        didRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for action in list.split(separator: ",") {
                switch action {
                case "next": c.nextDifference()
                case "prev": c.previousDifference()
                case "nextConflict": c.nextDifference(conflictsOnly: true)
                case "first": c.firstDifference()
                case "last": c.lastDifference()
                case "copyRight": c.copyRightward()
                case "copyLeft": c.copyLeftward()
                case "copyRightNext": c.copyRightward(advance: true)
                case "copyAllRight": c.copyAll(from: c.rightwardPanes.from, to: c.rightwardPanes.to)
                case "copyAllLeft": c.copyAll(from: c.leftwardPanes.from, to: c.leftwardPanes.to)
                case "autoMerge": c.autoMerge()
                case "undo": c.panes[0].textView.undoManager?.undo()
                case "saveAll": c.saveAll()
                case "saveRight": c.save(pane: c.paneCount - 1)
                case "saveLeft": c.save(pane: 0)
                case "typeLeft": c.panes[0].textView.insertText("Added line\n", replacementRange: NSRange(location: 0, length: 0))
                case "recompute": c.recomputeNow()
                case "swap": c.swapSides()
                case "wrap": c.wrapLines = true
                case "geometry":
                    for pane in c.panes {
                        let tv = pane.textView
                        FileHandle.standardError.write(Data("pane \(tv.paneIndex): clip=\(pane.scrollView.contentView.bounds) content=\(pane.scrollView.contentSize) tv=\(tv.frame) container=\(tv.textContainer!.containerSize) inset=\(tv.textContainerInset) origin=\(tv.textContainerOrigin) bounds=\(tv.bounds) frag0=\(tv.layoutManager!.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)) used0=\(tv.layoutManager!.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)) loc0=\(tv.layoutManager!.location(forGlyphAt: 0))\n".utf8))
                    }
                case "nowrap": c.wrapLines = false
                case "syncDemo":
                    // Put the left caret on line 3 and the right caret on line 2, then sync.
                    c.panes[0].textView.setSelectedRange(NSRange(location: c.lineStart(pane: 0, line: 2) ?? 0, length: 0))
                    c.panes[1].textView.setSelectedRange(NSRange(location: c.lineStart(pane: 1, line: 1) ?? 0, length: 0))
                    c.addSyncPoint()
                case "bookmark": c.toggleBookmark()
                case "crlfLeft": c.setLineEnding(.crlf, pane: 0)
                case "sjisLeft": c.setEncoding(.shiftJIS, bom: false, pane: 0)
                case "context0": c.diffContext = 0
                case "context2": c.diffContext = 2
                case "contextAll": c.diffContext = nil
                default: FileHandle.standardError.write(Data("unknown action \(action)\n".utf8))
                }
            }
            let kinds = c.hunks.map { "\($0.kind)" }.joined(separator: " ")
            let summary = "actions done: hunks=\(c.hunks.count) [\(kinds)] current=\(c.currentHunk.map(String.init) ?? "nil") dirty=\(c.info.map(\.isDirty)) status=\(c.statusMessage ?? "")\n"
            FileHandle.standardError.write(Data(summary.utf8))
        }
    }
}
