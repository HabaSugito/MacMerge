import XCTest
@testable import DiffCore

final class LineDiffTests: XCTestCase {
    func testIdentical() {
        XCTAssertEqual(diffLines(["a", "b"], ["a", "b"]), [.equal(left: 0..<2, right: 0..<2)])
    }

    func testChangedMiddleLine() {
        XCTAssertEqual(diffLines(["a", "b", "c"], ["a", "x", "c"]), [
            .equal(left: 0..<1, right: 0..<1),
            .changed(left: 1..<2, right: 1..<2),
            .equal(left: 2..<3, right: 2..<3),
        ])
    }

    func testInsertion() {
        XCTAssertEqual(diffLines(["a"], ["a", "b"]), [
            .equal(left: 0..<1, right: 0..<1),
            .changed(left: 1..<1, right: 1..<2),
        ])
    }

    func testEmptySides() {
        XCTAssertEqual(diffLines([], []), [])
        XCTAssertEqual(diffLines([], ["a"]), [.changed(left: 0..<0, right: 0..<1)])
        XCTAssertEqual(diffLines(["a"], []), [.changed(left: 0..<1, right: 0..<0)])
    }

    /// The number of unchanged lines must equal the longest common subsequence,
    /// which proves the diff is minimal.
    func testMatchesLCSOnRandomInput() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let a = (0..<Int.random(in: 0...40, using: &rng)).map { _ in String(Int.random(in: 0...4, using: &rng)) }
            let b = (0..<Int.random(in: 0...40, using: &rng)).map { _ in String(Int.random(in: 0...4, using: &rng)) }
            let blocks = diffLines(a, b)
            var kept = 0, ai = 0, bi = 0
            for block in blocks {
                switch block {
                case let .equal(l, r):
                    XCTAssertEqual(Array(a[l]), Array(b[r]))
                    XCTAssertEqual(l.lowerBound, ai); XCTAssertEqual(r.lowerBound, bi)
                    kept += l.count; ai = l.upperBound; bi = r.upperBound
                case let .changed(l, r):
                    XCTAssertEqual(l.lowerBound, ai); XCTAssertEqual(r.lowerBound, bi)
                    ai = l.upperBound; bi = r.upperBound
                }
            }
            XCTAssertEqual(ai, a.count); XCTAssertEqual(bi, b.count)
            XCTAssertEqual(kept, lcsLength(a, b), "a=\(a) b=\(b)")
        }
    }

    func testAlignedRows() {
        let c = LineComparison(left: ["a", "b", "c"], right: ["a", "c", "d", "e"])
        XCTAssertEqual(c.hunks.count, 2)
        XCTAssertEqual(c.rows, [
            AlignedRow(left: 0, right: 0, hunk: nil),
            AlignedRow(left: 1, right: nil, hunk: 0),
            AlignedRow(left: 2, right: 1, hunk: nil),
            AlignedRow(left: nil, right: 2, hunk: 1),
            AlignedRow(left: nil, right: 3, hunk: 1),
        ])
    }

    func testLargeInputIsFast() {
        let a = (0..<50_000).map { "line \($0)" }
        var b = a
        for i in stride(from: 0, to: b.count, by: 97) { b[i] = "changed \(i)" }
        measure { _ = diffLines(a, b) }
    }

    private func lcsLength(_ a: [String], _ b: [String]) -> Int {
        var t = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        return t[0][0]
    }
}

final class InlineDiffTests: XCTestCase {
    func testWordLevel() {
        let r = inlineDifferences("let x = 10", "let y = 10")
        XCTAssertEqual(r.left, [NSRange(location: 4, length: 1)])
        XCTAssertEqual(r.right, [NSRange(location: 4, length: 1)])
    }

    func testJapaneseCharactersAreSeparateWords() {
        let r = inlineDifferences("今日は晴れです", "今日は雨です")
        XCTAssertEqual(r.left, [NSRange(location: 3, length: 2)])
        XCTAssertEqual(r.right, [NSRange(location: 3, length: 1)])
    }

    func testUTF16Offsets() {
        // The emoji takes two UTF-16 units, so "b" starts at offset 3.
        let r = inlineDifferences("😀 a", "😀 b", granularity: .character)
        XCTAssertEqual(r.left, [NSRange(location: 3, length: 1)])
    }
}

final class TextFileTests: XCTestCase {
    func testCRLFRoundTrip() {
        let data = Data("a\r\nb\r\n".utf8)
        let f = TextFile.decode(data)
        XCTAssertEqual(f.text, "a\nb\n")
        XCTAssertEqual(f.lineEnding, .crlf)
        XCTAssertEqual(f.encode(f.text), data)
    }

    func testShiftJIS() {
        let data = "日本語".data(using: .shiftJIS)!
        let f = TextFile.decode(data)
        XCTAssertEqual(f.encoding, .shiftJIS)
        XCTAssertEqual(f.text, "日本語")
        XCTAssertEqual(f.encode(f.text), data)
    }

    func testUTF8BOM() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8)
        let f = TextFile.decode(data)
        XCTAssertTrue(f.hasBOM)
        XCTAssertEqual(f.text, "x")
        XCTAssertEqual(f.encode("x"), data)
    }

    func testBinary() {
        XCTAssertTrue(TextFile.decode(Data([0x50, 0x00, 0x01])).isBinary)
    }
}

final class FolderComparisonTests: XCTestCase {
    func testFolderComparison() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let l = root.appendingPathComponent("L"), r = root.appendingPathComponent("R")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ base: URL, _ path: String, _ text: String) throws {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(l, "same.txt", "a\n"); try write(r, "same.txt", "a\n")
        try write(l, "diff.txt", "a\nb\n"); try write(r, "diff.txt", "a\nc\n")
        try write(l, "only-left.txt", "x"); try write(r, "sub/only-right.txt", "y")

        let items = FolderComparer().compare(left: l, right: r)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(items.first?.name, "sub", "folders come first")
        XCTAssertEqual(byName["same.txt"]?.result, .identical)
        XCTAssertEqual(byName["diff.txt"]?.result, .different(diffCount: 1))
        XCTAssertEqual(byName["only-left.txt"]?.result, .leftOnly)
        XCTAssertEqual(byName["sub"]?.result, .rightOnly)
        XCTAssertEqual(byName["sub"]?.children?.first?.result, .rightOnly)
    }
}

final class InlineDiffMixedTests: XCTestCase {
    func testMixedWordsAndJapanese() {
        let r = inlineDifferences("line 49500 の内容です", "changed 49500 変更")
        XCTAssertEqual(r.left, [NSRange(location: 0, length: 4), NSRange(location: 11, length: 5)])
        XCTAssertEqual(r.right, [NSRange(location: 0, length: 7), NSRange(location: 14, length: 2)])
    }
}

final class CompareOptionsTests: XCTestCase {
    func testIgnoreWhitespaceChange() {
        let c = LineComparison(left: ["a  b", "x"], right: ["a b  ", "y"], options: CompareOptions(whitespace: .ignoreChange))
        XCTAssertEqual(c.hunks.count, 1)
        XCTAssertTrue(c.rows[0].isIgnored)
        XCTAssertNil(c.rows[0].hunk)
    }

    func testIgnoreAllWhitespaceAndCase() {
        let opts = CompareOptions(whitespace: .ignoreAll, ignoreCase: true)
        XCTAssertTrue(LineComparison(left: ["Let X=1"], right: ["let x = 1"], options: opts).hunks.isEmpty)
        XCTAssertEqual(LineComparison(left: ["Let X=1"], right: ["let x = 1"]).hunks.count, 1)
    }

    func testIgnoreBlankLines() {
        let c = LineComparison(left: ["a", "b"], right: ["a", "", "b"], options: CompareOptions(ignoreBlankLines: true))
        XCTAssertTrue(c.hunks.isEmpty)
        XCTAssertEqual(c.rows[1], AlignedRow(left: nil, right: 1, hunk: nil, isIgnored: true))
    }

    func testInlineIgnoresWhitespace() {
        let r = inlineDifferences("a  = 1", "a = 2", options: CompareOptions(whitespace: .ignoreChange))
        XCTAssertEqual(r.left, [NSRange(location: 5, length: 1)])
        XCTAssertEqual(r.right, [NSRange(location: 4, length: 1)])
    }
}

final class FileFilterTests: XCTestCase {
    func testMasks() {
        let f = FileFilter("*.swift;*.TXT;!test*;!build/;!.git\\")
        XCTAssertTrue(f.includesFile(named: "a.swift"))
        XCTAssertTrue(f.includesFile(named: "notes.txt"), "case-insensitive")
        XCTAssertFalse(f.includesFile(named: "a.o"))
        XCTAssertFalse(f.includesFile(named: "test.swift"))
        XCTAssertFalse(f.includesFolder(named: "build"))
        XCTAssertFalse(f.includesFolder(named: ".git"))
        XCTAssertTrue(f.includesFolder(named: "src"))
        XCTAssertTrue(FileFilter("*.*").includesFile(named: "Makefile"))
    }
}

final class FileOperationsTests: XCTestCase {
    func testCopyMergesFoldersAndReplacesFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dst.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "new".write(to: src.appendingPathComponent("sub/a.txt"), atomically: true, encoding: .utf8)
        try "old".write(to: dst.appendingPathComponent("sub/a.txt"), atomically: true, encoding: .utf8)
        try "keep".write(to: dst.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

        try FileOperations.copy(src.appendingPathComponent("sub"), to: dst.appendingPathComponent("sub"))
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("sub/a.txt"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("sub/b.txt"), encoding: .utf8), "keep")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dst.appendingPathComponent("sub").path).sorted(), ["a.txt", "b.txt"])
    }

    func testFolderCompareWithOptionsAndFilter() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let l = root.appendingPathComponent("L"), r = root.appendingPathComponent("R")
        try fm.createDirectory(at: l.appendingPathComponent("build"), withIntermediateDirectories: true)
        try fm.createDirectory(at: r, withIntermediateDirectories: true)
        try "a b\n".write(to: l.appendingPathComponent("ws.txt"), atomically: true, encoding: .utf8)
        try "a  b\n".write(to: r.appendingPathComponent("ws.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: l.appendingPathComponent("eol.txt"), atomically: true, encoding: .utf8)
        try "x\r\n".write(to: r.appendingPathComponent("eol.txt"), atomically: true, encoding: .utf8)
        try "o".write(to: l.appendingPathComponent("build/out.o"), atomically: true, encoding: .utf8)

        let plain = Dictionary(uniqueKeysWithValues: FolderComparer().compare(left: l, right: r).map { ($0.name, $0.result) })
        XCTAssertEqual(plain["ws.txt"], .different(diffCount: 1))
        XCTAssertEqual(plain["eol.txt"], .different(diffCount: 0))
        XCTAssertEqual(plain["build"], .leftOnly)

        let comparer = FolderComparer(options: CompareOptions(whitespace: .ignoreChange, ignoreLineEndings: true), filter: FileFilter("!build/"))
        let tuned = Dictionary(uniqueKeysWithValues: comparer.compare(left: l, right: r).map { ($0.name, $0.result) })
        XCTAssertEqual(tuned["ws.txt"], .identical)
        XCTAssertEqual(tuned["eol.txt"], .identical)
        XCTAssertNil(tuned["build"])
    }
}

final class SimilarLineTests: XCTestCase {
    func testSimilarLinesShareARow() {
        let c = LineComparison(left: ["", "let Total = add(a: 1, b: 2)"], right: ["let total = add(a: 1, b: 3)"])
        XCTAssertEqual(c.rows, [
            AlignedRow(left: 0, right: nil, hunk: 0),
            AlignedRow(left: 1, right: 0, hunk: 0),
        ])
    }

    func testUnrelatedLinesPairInOrder() {
        let c = LineComparison(left: ["aaaa", "bbbb"], right: ["xxxx"])
        XCTAssertEqual(c.rows.map(\.left), [0, 1])
        XCTAssertEqual(c.rows.map(\.right), [0, nil])
    }
}
