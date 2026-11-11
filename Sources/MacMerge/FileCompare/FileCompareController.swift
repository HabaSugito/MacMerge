import AppKit
import Combine
import DiffCore

struct PaneInfo {
    var url: URL
    var file: TextFile
    var isDirty = false
}

/// Owns both text panes of a file comparison and keeps them aligned, highlighted and in sync.
@MainActor
final class FileCompareController: NSObject, ObservableObject, NSTextViewDelegate {
    let target: CompareTarget
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let rowHeight: CGFloat
    let left: DiffPane
    let right: DiffPane

    @Published private(set) var hunks: [DiffHunk] = []
    @Published private(set) var rowCount = 0
    @Published private(set) var currentHunk: Int?
    /// Rows visible in the panes, for the location pane.
    @Published private(set) var visibleRows: Range<Int> = 0..<0
    @Published private(set) var info: [PaneInfo]
    @Published private(set) var loadError: String?
    @Published var showsInlineDifferences = true {
        didSet { redraw() }
    }

    private(set) var rows: [AlignedRow] = []
    private var lines: [[String]] = [[], []]
    private var lineStarts: [[Int]] = [[], []]
    private var lineToRow: [[Int]] = [[], []]
    private var leadingGhosts = [0, 0]
    private var inlineCache: [Int: (left: [NSRange], right: [NSRange])] = [:]
    private var pendingRecompute: DispatchWorkItem?
    private var isSyncingScroll = false
    private var isMovingCaret = false
    private var activeSide: Side = .left
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
        rowHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        left = DiffPane(side: .left, font: font)
        right = DiffPane(side: .right, font: font)
        info = [PaneInfo(url: target.left, file: .empty), PaneInfo(url: target.right, file: .empty)]
        super.init()
        for pane in [left, right] {
            pane.textView.controller = self
            pane.textView.delegate = self
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewScrolled(_:)), name: NSView.boundsDidChangeNotification, object: pane.scrollView.contentView)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        load()
        DebugActions.runIfRequested(on: self)
    }

    var isBinary: Bool { info[0].file.isBinary || info[1].file.isBinary }
    var binaryFilesIdentical: Bool {
        (try? Data(contentsOf: target.left)) == (try? Data(contentsOf: target.right))
    }

    func pane(_ side: Side) -> DiffPane { side == .left ? left : right }

    // MARK: Loading and diffing

    func load() {
        do {
            info[0].file = try TextFile.load(target.left)
            info[1].file = try TextFile.load(target.right)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        info[0].isDirty = false
        info[1].isDirty = false
        for side in [Side.left, .right] {
            let tv = pane(side).textView
            let attrs = baseAttributes(spacing: 0)
            tv.textStorage?.setAttributedString(NSAttributedString(string: info[side.rawValue].file.text, attributes: attrs))
            tv.typingAttributes = attrs
            tv.undoManager?.removeAllActions(withTarget: tv.textStorage as Any)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
        currentHunk = nil
        recomputeNow()
        updateDocumentEdited()
        if !hunks.isEmpty { select(hunk: 0) }
    }

    func recomputeNow() {
        pendingRecompute?.cancel()
        pendingRecompute = nil
        let texts = [left.textView.string, right.textView.string]
        lines = texts.map(splitLines)
        lineStarts = texts.map(Self.lineStarts)
        let comparison = LineComparison(left: lines[0], right: lines[1], options: options)
        rows = comparison.rows
        inlineCache = [:]

        lineToRow = [Array(repeating: 0, count: lines[0].count), Array(repeating: 0, count: lines[1].count)]
        for (r, row) in rows.enumerated() {
            if let l = row.left { lineToRow[0][l] = r }
            if let rr = row.right { lineToRow[1][rr] = r }
        }
        applyLayout(side: .left)
        applyLayout(side: .right)

        hunks = comparison.hunks
        rowCount = rows.count
        if let c = currentHunk, c >= hunks.count { currentHunk = hunks.isEmpty ? nil : hunks.count - 1 }
        updateVisibleRows()
        redraw()
    }

    private func scheduleRecompute() {
        pendingRecompute?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recomputeNow() }
        pendingRecompute = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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

    /// Adds paragraph spacing under lines that are followed by filler rows, so both sides line up.
    private func applyLayout(side: Side) {
        let s = side.rawValue
        let tv = pane(side).textView
        guard let storage = tv.textStorage else { return }

        var leading = 0
        var spacingAfter: [Int: Int] = [:]
        var lastLine: Int?
        var ghosts = 0
        for row in rows {
            if let line = side == .left ? row.left : row.right {
                if ghosts > 0 {
                    if let lastLine { spacingAfter[lastLine] = ghosts } else { leading = ghosts }
                }
                ghosts = 0
                lastLine = line
            } else {
                ghosts += 1
            }
        }
        leadingGhosts[s] = leading

        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.paragraphStyle, value: baseAttributes(spacing: 0)[.paragraphStyle]!, range: full)
        for (line, count) in spacingAfter {
            guard line + 1 < lineStarts[s].count else { continue }
            let start = lineStarts[s][line]
            let range = NSRange(location: start, length: lineStarts[s][line + 1] - start)
            guard NSMaxRange(range) <= storage.length else { continue }
            storage.addAttribute(.paragraphStyle, value: baseAttributes(spacing: CGFloat(count) * rowHeight)[.paragraphStyle]!, range: range)
        }
        storage.endEditing()
        tv.typingAttributes = baseAttributes(spacing: 0)
        tv.textContainerInset = NSSize(width: 4, height: CGFloat(leading) * rowHeight)

        let height = CGFloat(rows.count + max(leadingGhosts[0], leadingGhosts[1])) * rowHeight + 40
        tv.minSize = NSSize(width: 0, height: height)
        tv.sizeToFit()
    }

    func redraw() {
        for pane in [left, right] {
            pane.textView.needsDisplay = true
            pane.scrollView.verticalRulerView?.needsDisplay = true
        }
    }

    // MARK: Geometry used by drawing

    /// The y position of row 0 in the text view's coordinates.
    func rowOriginY(in textView: NSTextView, side: Side) -> CGFloat {
        textView.textContainerOrigin.y - CGFloat(leadingGhosts[side.rawValue]) * rowHeight
    }

    func lineStart(side: Side, line: Int) -> Int? {
        let starts = lineStarts[side.rawValue]
        return line < starts.count ? starts[line] : nil
    }

    func inlineRanges(row: Int, side: Side) -> [NSRange] {
        if let cached = inlineCache[row] { return side == .left ? cached.left : cached.right }
        var result: (left: [NSRange], right: [NSRange]) = ([], [])
        let r = rows[row]
        if let l = r.left, let rr = r.right, l < lines[0].count, rr < lines[1].count {
            let a = lines[0][l], b = lines[1][rr]
            if a.utf16.count < 5000, b.utf16.count < 5000 {
                result = inlineDifferences(a, b, options: options)
            }
        }
        inlineCache[row] = result
        return side == .left ? result.left : result.right
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
        let target = source === left.scrollView.contentView ? right.scrollView : left.scrollView
        let clip = target.contentView
        let origin = clip.constrainBoundsRect(NSRect(origin: source.bounds.origin, size: clip.bounds.size)).origin
        clip.setBoundsOrigin(origin)
        target.reflectScrolledClipView(clip)
        isSyncingScroll = false
        updateVisibleRows()
    }

    private func updateVisibleRows() {
        let tv = left.textView
        let visible = left.scrollView.contentView.bounds
        let top = rowOriginY(in: tv, side: .left)
        let first = max(0, Int((visible.minY - top) / rowHeight))
        let last = max(first, min(rows.count, Int(ceil((visible.maxY - top) / rowHeight))))
        let range = first..<last
        if range != visibleRows { visibleRows = range }
    }

    /// Scrolls so that `row` sits about a third of the way down the panes.
    func scrollToRow(_ row: Int, centered: Bool = true) {
        let tv = left.textView
        let clip = left.scrollView.contentView
        let y = rowOriginY(in: tv, side: .left) + CGFloat(row) * rowHeight
        let offset = centered ? clip.bounds.height / 3 : 0
        let origin = clip.constrainBoundsRect(NSRect(x: clip.bounds.minX, y: y - offset, width: clip.bounds.width, height: clip.bounds.height)).origin
        clip.setBoundsOrigin(origin)
        left.scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Selection and navigation

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? DiffTextView, !isMovingCaret, pendingRecompute == nil else { return }
        activeSide = tv.side
        let row = caretRow(side: tv.side)
        if let hunk = rows.indices.contains(row) ? rows[row].hunk : nil, hunk != currentHunk {
            currentHunk = hunk
            redraw()
        }
    }

    func textDidBeginEditing(_ notification: Notification) {
        if let tv = notification.object as? DiffTextView { activeSide = tv.side }
    }

    private func caretRow(side: Side) -> Int {
        let s = side.rawValue
        let tv = pane(side).textView
        let location = tv.selectedRange().location
        let starts = lineStarts[s]
        guard !starts.isEmpty else { return 0 }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo < lineToRow[s].count ? lineToRow[s][lo] : 0
    }

    var canGoNext: Bool {
        guard let last = hunks.indices.last else { return false }
        return (currentHunk ?? -1) < last
    }

    var canGoPrevious: Bool {
        guard !hunks.isEmpty else { return false }
        if let c = currentHunk { return c > 0 }
        return hunks.contains { $0.rows.upperBound <= caretRow(side: activeSide) }
    }

    func nextDifference() {
        if pendingRecompute != nil { recomputeNow() }
        if let c = currentHunk {
            if c + 1 < hunks.count { select(hunk: c + 1) }
        } else {
            let row = caretRow(side: activeSide)
            if let i = hunks.firstIndex(where: { $0.rows.lowerBound >= row }) { select(hunk: i) }
        }
    }

    func previousDifference() {
        if pendingRecompute != nil { recomputeNow() }
        if let c = currentHunk {
            if c > 0 { select(hunk: c - 1) }
        } else {
            let row = caretRow(side: activeSide)
            if let i = hunks.lastIndex(where: { $0.rows.upperBound <= row }) { select(hunk: i) }
        }
    }

    func firstDifference() { if !hunks.isEmpty { select(hunk: 0) } }
    func lastDifference() { if !hunks.isEmpty { select(hunk: hunks.count - 1) } }
    func currentDifference() { if let c = currentHunk { select(hunk: c) } }

    func select(hunk index: Int) {
        guard hunks.indices.contains(index) else { return }
        currentHunk = index
        let hunk = hunks[index]
        // Put the caret at the start of the difference in the pane being worked in.
        let s = activeSide.rawValue
        let lineRange = activeSide == .left ? hunk.left : hunk.right
        let line = min(lineRange.lowerBound, max(0, lineStarts[s].count - 1))
        if let start = lineStart(side: activeSide, line: line) {
            isMovingCaret = true
            pane(activeSide).textView.setSelectedRange(NSRange(location: start, length: 0))
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

    var canCopy: Bool { currentHunk != nil && !hunks.isEmpty }

    /// Copies the current difference from `side` to the other side.
    func copyCurrent(from side: Side, advance: Bool = false) {
        if pendingRecompute != nil { recomputeNow() }
        guard let index = currentHunk, hunks.indices.contains(index) else { return }
        let undo = pane(side.other).textView.undoManager
        undo?.beginUndoGrouping()
        apply(hunk: hunks[index], from: side)
        undo?.endUndoGrouping()
        undo?.setActionName(side == .left ? "右へコピー" : "左へコピー")
        recomputeNow()
        if advance, !hunks.isEmpty {
            select(hunk: min(index, hunks.count - 1))
        } else {
            currentHunk = nil
            redraw()
        }
    }

    func copyAll(from side: Side) {
        if pendingRecompute != nil { recomputeNow() }
        guard !hunks.isEmpty else { return }
        let undo = pane(side.other).textView.undoManager
        undo?.beginUndoGrouping()
        // Work from the bottom up so earlier line numbers stay valid.
        for hunk in hunks.reversed() { apply(hunk: hunk, from: side) }
        undo?.endUndoGrouping()
        undo?.setActionName("すべてコピー")
        currentHunk = nil
        recomputeNow()
    }

    private func apply(hunk: DiffHunk, from side: Side) {
        let src = side == .left ? hunk.left : hunk.right
        let dst = side == .left ? hunk.right : hunk.left
        let newLines = Array(lines[side.rawValue][src])
        replaceLines(side: side.other, range: dst, with: newLines)
    }

    /// Replaces whole lines through the text view so the change can be undone.
    private func replaceLines(side: Side, range: Range<Int>, with newLines: [String]) {
        let s = side.rawValue
        let tv = pane(side).textView
        let starts = lineStarts[s]
        let current = lines[s]
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

    // MARK: Editing and saving

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? DiffTextView else { return }
        if !info[tv.side.rawValue].isDirty {
            info[tv.side.rawValue].isDirty = true
            updateDocumentEdited()
        }
        scheduleRecompute()
    }

    var isDirty: Bool { info[0].isDirty || info[1].isDirty }

    @discardableResult
    func save(_ side: Side) -> Bool {
        let s = side.rawValue
        var file = info[s].file
        let text = pane(side).textView.string
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
            try data!.write(to: info[s].url, options: .atomic)
            file.text = text
            file.exists = true
            info[s].file = file
            info[s].isDirty = false
            updateDocumentEdited()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    func saveAll() {
        for side in [Side.left, .right] where info[side.rawValue].isDirty {
            save(side)
        }
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
                case "first": c.firstDifference()
                case "last": c.lastDifference()
                case "copyRight": c.copyCurrent(from: .left)
                case "copyLeft": c.copyCurrent(from: .right)
                case "copyRightNext": c.copyCurrent(from: .left, advance: true)
                case "copyAllRight": c.copyAll(from: .left)
                case "copyAllLeft": c.copyAll(from: .right)
                case "undo": c.right.textView.undoManager?.undo()
                case "saveRight": c.save(.right)
                case "saveLeft": c.save(.left)
                case "typeLeft": c.left.textView.insertText("追加した行\n", replacementRange: NSRange(location: 0, length: 0))
                case "recompute": c.recomputeNow()
                default: FileHandle.standardError.write(Data("unknown action \(action)\n".utf8))
                }
            }
            let summary = "actions done: hunks=\(c.hunks.count) current=\(c.currentHunk.map(String.init) ?? "nil") dirty=\(c.info.map(\.isDirty))\n"
            FileHandle.standardError.write(Data(summary.utf8))
        }
    }
}
