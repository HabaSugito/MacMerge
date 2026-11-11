import AppKit
import DiffCore
import XCTest
@testable import MacMergeUI

@MainActor
final class FolderCompareTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacMergeFolderTests-\(UUID().uuidString)")
        UserDefaults.standard.removeObject(forKey: CompareSettings.fileFilterKey)
        UserDefaults.standard.set(true, forKey: "folder.treeMode")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func waitForCompare(_ model: FolderCompareModel) {
        let end = Date().addingTimeInterval(5)
        repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } while model.isComparing && Date() < end
    }

    func testFlatViewCopyAndPatch() throws {
        try write("L/sub/only.txt", "x\n")
        try write("L/diff.txt", "a\n")
        try write("R/diff.txt", "b\n")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("R/sub"), withIntermediateDirectories: true)
        let model = FolderCompareModel(target: CompareTarget(left: dir.appendingPathComponent("L"), right: dir.appendingPathComponent("R"), kind: .folders))
        waitForCompare(model)
        XCTAssertEqual(model.visibleItems.map(\.name).sorted(), ["diff.txt", "sub"])

        model.treeMode = false
        XCTAssertEqual(model.visibleItems.map(\.id).sorted(), ["diff.txt", "sub/only.txt"])

        XCTAssertTrue(model.makePatch().contains("--- a/diff.txt\n+++ b/diff.txt\n@@ -1 +1 @@\n-a\n+b\n"))

        let only = try XCTUnwrap(model.find("sub/only.txt"))
        XCTAssertTrue(model.performCopy([only], toRight: true).isEmpty)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("R/sub/only.txt"), encoding: .utf8), "x\n")
        waitForCompare(model)
        XCTAssertEqual(model.find("sub/only.txt")?.result, .identical)
    }

    func testTrash() throws {
        try write("L/a.txt", "a")
        try write("R/a.txt", "b")
        let model = FolderCompareModel(target: CompareTarget(left: dir.appendingPathComponent("L"), right: dir.appendingPathComponent("R"), kind: .folders))
        waitForCompare(model)
        let item = try XCTUnwrap(model.find("a.txt"))
        XCTAssertTrue(model.performTrash([item], left: false, right: true).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("R/a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("L/a.txt").path))
    }
}

final class OpenAndProjectTests: XCTestCase {
    func testCompareRequestChecksPaths() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)
        let folder = dir.appendingPathComponent("folder").path

        XCTAssertEqual(try CompareRequest.target(left: a.path, right: b.path).get().kind, .files)
        XCTAssertEqual(try CompareRequest.target(left: folder, right: folder).get().kind, .folders)
        XCTAssertNotNil(try CompareRequest.target(left: a.path, middle: b.path, right: a.path).get().middle)
        XCTAssertThrowsError(try CompareRequest.target(left: dir.appendingPathComponent("none").path, right: b.path).get())
        XCTAssertThrowsError(try CompareRequest.target(left: a.path, right: folder).get())
        XCTAssertThrowsError(try CompareRequest.target(left: folder, middle: folder, right: folder).get())
    }

    func testProjectFileRoundTrip() throws {
        let target = CompareTarget(left: URL(filePath: "/tmp/a"), right: URL(filePath: "/tmp/b"), middle: URL(filePath: "/tmp/base"), output: URL(filePath: "/tmp/out"), kind: .files)
        let data = try JSONEncoder().encode(ProjectFile(target: target))
        XCTAssertEqual(try JSONDecoder().decode(ProjectFile.self, from: data).target, target)
    }
}

/// Every fixed user-facing string in the app must have a Japanese translation.
final class TranslationTests: XCTestCase {
    func testJapaneseCoversAllStrings() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let table = try XCTUnwrap(NSDictionary(contentsOf: root.appending(path: "Resources/ja.lproj/Localizable.strings")) as? [String: String])
        let calls = ["L", "Text", "Button", "Label", "Toggle", "Section", "help", "TableColumn", "Menu", "CommandMenu",
                     "Picker", "TextField", "ContentUnavailableView", "ProgressView", "ColorPicker"]
        let pattern = try NSRegularExpression(pattern: "\\b(?:" + calls.joined(separator: "|") + ")\\(\"((?:[^\"\\\\]|\\\\.)*)\"")
        let notUserFacing: Set<String> = ["", "Added line\\n"]
        var missing: [String] = []
        let files = FileManager.default.enumerator(at: root.appending(path: "Sources"), includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = String(text[Range(match.range(at: 1), in: text)!])
                guard !literal.contains("\\("), !notUserFacing.contains(literal) else { continue }
                let key = literal.replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
                if table[key] == nil { missing.append("\(url.lastPathComponent): \(key)") }
            }
        }
        XCTAssertEqual(missing, [], "Add these to Resources/ja.lproj/Localizable.strings")
    }
}
