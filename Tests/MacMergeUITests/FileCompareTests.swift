import AppKit
import DiffCore
import XCTest
@testable import MacMergeUI

/// Tests of the file comparison window's controller, with its panes placed in a real window
/// so layout, undo and key handling behave as in the app.
@MainActor
final class FileCompareTests: XCTestCase {
    private var dir: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacMergeUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for key in ["view.diffContext", "editor.wrapLines", CompareSettings.whitespaceKey, CompareSettings.ignoreCaseKey,
                    CompareSettings.ignoreBlankLinesKey, CompareSettings.detectMovedBlocksKey, CompareSettings.lineFiltersKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Opens a comparison with its panes side by side in a window.
    private func open(_ target: CompareTarget, width: CGFloat = 1200) -> FileCompareController {
        let c = FileCompareController(target: target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stack = NSStackView(views: c.panes.map(\.scrollView))
        stack.distribution = .fillEqually
        window.contentView = stack
        window.layoutIfNeeded()
        windows.append(window)
        c.recomputeNow()
        return c
    }

    private func twoWay(_ left: String, _ right: String) throws -> FileCompareController {
        open(CompareTarget(left: try file("left.txt", left), right: try file("right.txt", right), kind: .files))
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testCopyAndSave() throws {
        let c = try twoWay("a\nb\nc\n", "a\nX\nc\n")
        XCTAssertEqual(c.hunks.count, 1)
        c.select(hunk: 0)
        c.copyRightward()
        XCTAssertEqual(c.panes[1].textView.string, "a\nb\nc\n")
        XCTAssertTrue(c.hunks.isEmpty)
        XCTAssertTrue(c.isDirty)
        XCTAssertTrue(c.save(pane: 1))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("right.txt"), encoding: .utf8), "a\nb\nc\n")
        XCTAssertFalse(c.isDirty)
    }

    func testUndoCopy() throws {
        let c = try twoWay("a\nb\n", "a\nc\n")
        c.select(hunk: 0)
        c.copyLeftward()
        XCTAssertEqual(c.panes[0].textView.string, "a\nc\n")
        c.panes[0].textView.undoManager?.undo()
        c.recomputeNow()
        XCTAssertEqual(c.panes[0].textView.string, "a\nb\n")
        XCTAssertEqual(c.hunks.count, 1)
    }

    func testThreeWayAutoMerge() throws {
        let base = (1...9).map { "line\($0)" }
        var mine = base, theirs = base
        mine[1] = "mine2"; theirs[4] = "theirs5"; mine[7] = "mine8"; theirs[7] = "theirs8"
        let c = open(CompareTarget(left: try file("mine.txt", mine.joined(separator: "\n")),
                                   right: try file("theirs.txt", theirs.joined(separator: "\n")),
                                   middle: try file("base.txt", base.joined(separator: "\n")), kind: .files))
        XCTAssertEqual(c.hunks.map(\.kind), [.leftOnly, .rightOnly, .conflict])
        c.autoMerge()
        var expected = base
        expected[1] = "mine2"; expected[4] = "theirs5"
        XCTAssertEqual(c.panes[1].textView.string, expected.joined(separator: "\n"))
        XCTAssertEqual(c.conflictCount, 1)
    }

    func testConflictFileResolvesAndSaves() throws {
        let url = try file("conflict.txt", "start\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> feature\nend\n")
        let c = open(.conflict(url))
        XCTAssertEqual(c.paneCount, 3)
        XCTAssertEqual(c.panes[0].textView.string, "start\nmine\nend\n")
        XCTAssertEqual(c.panes[2].textView.string, "start\ntheirs\nend\n")
        XCTAssertEqual(c.conflictCount, 1)
        c.select(hunk: 0)
        c.copyLeftward() // take theirs
        c.saveAll()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "start\ntheirs\nend\n")
    }

    func testFoldingShowsOnlyLinesAroundDifferences() throws {
        let left = (1...100).map { "line \($0)" }
        var right = left
        right[49] = "changed"
        let c = try twoWay(left.joined(separator: "\n"), right.joined(separator: "\n"))
        XCTAssertEqual(c.shownRows.count, 100)
        c.diffContext = 2
        XCTAssertEqual(c.shownRows, Array(47...51))
        c.diffContext = nil
        XCTAssertEqual(c.shownRows.count, 100)
    }

    func testSyncPoint() throws {
        let c = try twoWay("a\nb\nc\nd", "a\nb\nd")
        c.panes[0].textView.setSelectedRange(NSRange(location: c.lineStart(pane: 0, line: 2)!, length: 0))
        c.panes[1].textView.setSelectedRange(NSRange(location: c.lineStart(pane: 1, line: 1)!, length: 0))
        c.addSyncPoint()
        XCTAssertEqual(c.rows.map(\.left), [0, 1, 2, 3])
        XCTAssertEqual(c.rows.map(\.right), [0, nil, 1, 2])
        c.clearSyncPoints()
        XCTAssertEqual(c.rows.map(\.right), [0, 1, nil, 2])
    }

    func testSaveWithOtherEncodingAndLineEnding() throws {
        let c = try twoWay("日本\n", "日本\n")
        c.setEncoding(.shiftJIS, bom: false, pane: 0)
        c.setLineEnding(.crlf, pane: 0)
        XCTAssertTrue(c.isDirty)
        XCTAssertTrue(c.save(pane: 0))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("left.txt")), "日本\r\n".data(using: .shiftJIS))
    }

    func testReopenWithEncoding() throws {
        let c = try twoWay("é\n", "e\n")
        c.reopen(pane: 0, as: .isoLatin1)
        XCTAssertEqual(c.panes[0].textView.string, "Ã©\n")
        XCTAssertEqual(c.info[0].file.encoding, .isoLatin1)
    }

    func testMergeModeArrowKeys() throws {
        let c = try twoWay("a\nb\nc\nd\ne\n", "a\nB\nc\nD\ne\n")
        XCTAssertEqual(c.currentHunk, 0)
        c.mergeMode = true
        func press(_ key: Int) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: c.panes[0].textView.window?.windowNumber ?? 0, context: nil,
                                         characters: String(UnicodeScalar(UInt16(key))!), charactersIgnoringModifiers: String(UnicodeScalar(UInt16(key))!),
                                         isARepeat: false, keyCode: 0)!
            c.panes[0].textView.keyDown(with: event)
        }
        press(NSDownArrowFunctionKey)
        XCTAssertEqual(c.currentHunk, 1)
        press(NSRightArrowFunctionKey)
        XCTAssertEqual(c.panes[1].textView.string, "a\nB\nc\nd\ne\n")
        c.mergeMode = false
        press(NSUpArrowFunctionKey) // now an ordinary caret move
        XCTAssertEqual(c.hunks.count, 1)
    }

    func testGoToLineAndBookmarks() throws {
        let c = try twoWay("1\n2\n3\n4\n", "1\n2\n3\n4\n")
        c.goToLine(3)
        XCTAssertEqual(c.caretLine(pane: 0), 2)
        c.toggleBookmark()
        c.goToLine(1)
        c.nextBookmark()
        XCTAssertEqual(c.caretLine(pane: 0), 2)
        c.clearBookmarks()
        XCTAssertTrue(c.info[0].bookmarks.isEmpty)
    }

    func testSwapSides() throws {
        let c = try twoWay("left\n", "right\n")
        c.swapSides()
        XCTAssertEqual(c.panes[0].textView.string, "right\n")
        XCTAssertEqual(c.info[0].url?.lastPathComponent, "right.txt")
        XCTAssertEqual(c.info[1].url?.lastPathComponent, "left.txt")
    }

    func testReadOnly() throws {
        let c = try twoWay("a\n", "b\n")
        c.setReadOnly(true, pane: 1)
        XCTAssertFalse(c.panes[1].textView.isEditable)
    }

    func testWrappedLinesKeepRowsAligned() throws {
        let long = String(repeating: "word ", count: 80)
        let c = open(CompareTarget(left: try file("l.txt", "a\n\(long)\nz\n"), right: try file("r.txt", "a\nshort\nz\n"), kind: .files), width: 700)
        c.wrapLines = true
        // A width change re-measures the rows shortly afterwards; let that happen.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let row = c.rows.firstIndex { $0.hunk != nil }!
        XCTAssertGreaterThan(c.rowHeights[row], c.rowHeight * 2, "the long line wraps")
        // The line after the wrapped row starts at the same height in both panes.
        let next = row + 1
        let y0 = c.panes[0].textView.layoutManager!.lineFragmentRect(forGlyphAt: c.lineStart(pane: 0, line: 2)!, effectiveRange: nil).minY
        let y1 = c.panes[1].textView.layoutManager!.lineFragmentRect(forGlyphAt: c.lineStart(pane: 1, line: 2)!, effectiveRange: nil).minY
        XCTAssertEqual(y0 + c.panes[0].textView.textContainerOrigin.y, y1 + c.panes[1].textView.textContainerOrigin.y, accuracy: 0.5)
        XCTAssertEqual(c.shownTops[next], c.rowHeight + c.rowHeights[row], accuracy: 0.5)
        c.wrapLines = false
        XCTAssertEqual(c.rowHeights[row], c.rowHeight)
    }

    func testReloadsFileChangedByAnotherApp() throws {
        let c = try twoWay("old\n", "old\n")
        try "new\n".write(to: dir.appendingPathComponent("left.txt"), atomically: true, encoding: .utf8)
        waitUntil { c.panes[0].textView.string == "new\n" }
        XCTAssertEqual(c.panes[0].textView.string, "new\n")
        XCTAssertEqual(c.hunks.count, 1)
    }

    func testPatchAndReport() throws {
        let c = try twoWay("a\nb\n", "a\nc\n")
        XCTAssertTrue(c.makePatch().contains("-b\n+c\n"))
        XCTAssertTrue(c.makeReport().contains("<table>"))
    }
}
