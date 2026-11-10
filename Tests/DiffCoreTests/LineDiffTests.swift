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
}
