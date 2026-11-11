import AppKit
import Combine
import DiffCore

struct PaneInfo {
    /// Where this pane is saved. Nil for panes that cannot be saved (the sides of a conflict file).
    var url: URL?
    var title: String
    var file: TextFile
    var isDirty = false
}

/// Owns the text panes of a file comparison (2 panes, or 3 for a three-way merge) and keeps
/// them aligned, highlighted and in sync.
@MainActor
final class FileCompareController: NSObject, ObservableObject, NSTextViewDelegate {
    let target: CompareTarget
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let rowHeight: CGFloat
    let panes: [DiffPane]

    @Published private(set) var hunks: [DiffHunk] = []
    @Published private(set) var rowCount = 0
    @Published private(set) var currentHunk: Int?
    /// Rows visible in the panes, for the location pane.
    @Published private(set) var visibleRows: Range<Int> = 0..<0
    @Published private(set) var info: [PaneInfo]
    @Published private(set) var loadError: String?
    @Published private(set) var statusMessage: String?
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
    private var leadingGhosts: [Int]
    private var inlineCache: [Int: [[NSRange]]] = [:]
    private var pendingRecompute: DispatchWorkItem?
    private var isSyncingScroll = false
    private var isMovingCaret = false
    private var activePane = 0
    private var closeGuard: WindowCloseGuard?
    private(set) var options = CompareSettings.options

    weak var window: NSWindow? {
        didSet {
            guard let window, window !== oldValue else { return }
            closeGuard = WindowCloseGuard(window: window) { [weak self] in self?.confirmClose() ?? true }
            updateDocumentEdited()
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
        leadingGhosts = Array(repeating: 0, count: count)
        info = Self.initialInfo(target)
        super.init()
        for pane in panes {
            pane.textView.controller = self
            pane.textView.delegate = self
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewScrolled(_:)), name: NSView.boundsDidChangeNotification, object: pane.scrollView.contentView)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        load()
        DebugActions.runIfRequested(on: self)
    }

    private static func initialInfo(_ t: CompareTarget) -> [PaneInfo] {
        switch t.kind {
        case .conflict:
            return [PaneInfo(url: nil, title: "自分の変更", file: .empty),
                    PaneInfo(url: t.left, title: t.left.path(percentEncoded: false), file: .empty),
                    PaneInfo(url: nil, title: "相手の変更", file: .empty)]
        default:
            var list = [PaneInfo(url: t.left, title: t.left.path(percentEncoded: false), file: .empty)]
            if let middle = t.middle {
                let saveTo = t.output ?? middle
                var title = middle.path(percentEncoded: false)
                if saveTo != middle { title += "（保存先: \(saveTo.lastPathComponent)）" }
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
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "コンフリクトの印（<<<<<<< と >>>>>>>）が見つかりません。"])
                }
                var ours = file, base = file, theirs = file
                ours.text = conflict.ours; base.text = conflict.base; theirs.text = conflict.theirs
                texts = [ours, base, theirs]
                if !conflict.oursLabel.isEmpty { info[0].title = "自分の変更（\(conflict.oursLabel)）" }
                if !conflict.theirsLabel.isEmpty { info[2].title = "相手の変更（\(conflict.theirsLabel)）" }
                statusMessage = "コンフリクトの印 \(conflict.conflictCount) 箇所を読み込みました。中央が保存される結果です"
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
            let comparison = LineComparison(left: lines[0], right: lines[1], options: options)
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
        updateFolding()
        for p in 0..<paneCount { applyLayout(pane: p) }

        rowCount = rows.count
        if let c = currentHunk, c >= hunks.count { currentHunk = hunks.isEmpty ? nil : hunks.count - 1 }
        updateVisibleRows()
        redraw()
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
        return [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: style]
    }

    /// Adds paragraph spacing under lines that are followed by filler rows, so all panes line up.
    private func applyLayout(pane p: Int) {
        let tv = panes[p].textView
        guard let storage = tv.textStorage else { return }

        var leading = 0
        var spacingAfter: [Int: Int] = [:]
        var lastLine: Int?
        var ghosts = 0
        for row in rows {
            if let l = line(row, pane: p) {
                if ghosts > 0 {
                    if let lastLine { spacingAfter[lastLine] = ghosts } else { leading = ghosts }
                }
                ghosts = 0
                lastLine = l
            } else {
                ghosts += 1
            }
        }
        leadingGhosts[p] = leading

        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.paragraphStyle, value: baseAttributes(spacing: 0)[.paragraphStyle]!, range: full)
        for (l, count) in spacingAfter {
            guard l + 1 < lineStarts[p].count else { continue }
            let start = lineStarts[p][l]
            let range = NSRange(location: start, length: lineStarts[p][l + 1] - start)
            guard NSMaxRange(range) <= storage.length else { continue }
            storage.addAttribute(.paragraphStyle, value: baseAttributes(spacing: CGFloat(count) * rowHeight)[.paragraphStyle]!, range: range)
        }
        storage.endEditing()
        tv.typingAttributes = baseAttributes(spacing: 0)
        tv.textContainerInset = NSSize(width: 4, height: CGFloat(leading) * rowHeight)

        let height = CGFloat(shownRows.count + (leadingGhosts.max() ?? 0)) * rowHeight + 40
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
        textView.textContainerOrigin.y - CGFloat(leadingGhosts[pane]) * rowHeight
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
        guard new != options else { return }
        options = new
        currentHunk = nil
        recomputeNow()
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

    private func updateVisibleRows() {
        let tv = panes[0].textView
        let visible = panes[0].scrollView.contentView.bounds
        let top = rowOriginY(in: tv, pane: 0)
        let first = max(0, Int((visible.minY - top) / rowHeight))
        let last = max(first, min(shownRows.count, Int(ceil((visible.maxY - top) / rowHeight))))
        let range = first < last ? shownRows[first]..<(shownRows[last - 1] + 1) : 0..<0
        if range != visibleRows { visibleRows = range }
    }

    /// Scrolls so that `row` sits about a third of the way down the panes.
    func scrollToRow(_ row: Int, centered: Bool = true) {
        let tv = panes[0].textView
        let clip = panes[0].scrollView.contentView
        let shown = displayIndex.indices.contains(row) ? displayIndex[row] : row
        let y = rowOriginY(in: tv, pane: 0) + CGFloat(shown) * rowHeight
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
        undo?.setActionName("差分をコピー")
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
        undo?.setActionName("すべてコピー")
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
            statusMessage = "自動でマージできる差分はありません"
            return
        }
        let undo = panes[1].textView.undoManager
        undo?.beginUndoGrouping()
        for hunk in mergeable.reversed() {
            apply(hunk, from: hunk.kind == .rightOnly ? 2 : 0, to: 1)
        }
        undo?.endUndoGrouping()
        undo?.setActionName("自動マージ")
        currentHunk = nil
        recomputeNow()
        let left = conflictCount
        statusMessage = "\(mergeable.count) 箇所を自動でマージしました" + (left > 0 ? "。残りのコンフリクトは \(left) 箇所です" : "")
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
            alert.messageText = "\(file.encodingName) では保存できない文字が含まれています"
            alert.informativeText = "UTF-8 で保存しますか？"
            alert.addButton(withTitle: "UTF-8 で保存")
            alert.addButton(withTitle: "キャンセル")
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
            alert.messageText = "まだ \(conflictCount) 箇所のコンフリクトが残っています"
            alert.informativeText = "このまま保存すると、残ったコンフリクトの部分は中央の内容（空の場合あり）になります。"
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for p in 0..<paneCount where info[p].isDirty { save(pane: p) }
    }

    func reload() {
        guard confirmDiscard(message: "ファイルを読み直すと、保存していない変更は失われます。") else { return }
        load()
    }

    private func updateDocumentEdited() {
        window?.isDocumentEdited = isDirty
    }

    private func confirmDiscard(message: String) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "保存していない変更があります"
        alert.informativeText = message
        alert.addButton(withTitle: "続ける")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks what to do with unsaved changes before the window closes.
    private func confirmClose() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "変更を保存しますか？"
        alert.informativeText = "保存しないと、変更は失われます。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "保存しない")
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
                case "typeLeft": c.panes[0].textView.insertText("追加した行\n", replacementRange: NSRange(location: 0, length: 0))
                case "recompute": c.recomputeNow()
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
