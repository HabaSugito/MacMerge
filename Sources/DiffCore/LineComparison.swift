import Foundation

/// One block of lines in a two-way comparison.
public enum DiffBlock: Equatable {
    case equal(left: Range<Int>, right: Range<Int>)
    case changed(left: Range<Int>, right: Range<Int>)
}

/// A run of differing lines. Either side may be empty (pure insertion or deletion).
public struct DiffHunk: Equatable {
    public var left: Range<Int>
    public var right: Range<Int>
    /// Rows this hunk occupies in the aligned side-by-side view.
    public var rows: Range<Int>
}

/// One row of the side-by-side view. A nil line means a filler ("ghost") row on that side.
public struct AlignedRow: Equatable {
    public var left: Int?
    public var right: Int?
    public var hunk: Int?

    public init(left: Int?, right: Int?, hunk: Int?) {
        self.left = left
        self.right = right
        self.hunk = hunk
    }
}

/// Compares two arrays of lines with Myers' algorithm.
public func diffLines(_ a: [String], _ b: [String]) -> [DiffBlock] {
    var interner = Interner<String>()
    let ia = a.map { interner.id($0) }
    let ib = b.map { interner.id($0) }
    let diff = MyersDiff(ia, ib)
    return blocks(deleted: diff.deleted, inserted: diff.inserted)
}

func blocks(deleted: [Bool], inserted: [Bool]) -> [DiffBlock] {
    let n = deleted.count, m = inserted.count
    var result: [DiffBlock] = []
    var i = 0, j = 0
    while i < n || j < m {
        if i < n, j < m, !deleted[i], !inserted[j] {
            let si = i, sj = j
            while i < n, j < m, !deleted[i], !inserted[j] { i += 1; j += 1 }
            result.append(.equal(left: si..<i, right: sj..<j))
        } else {
            let si = i, sj = j
            while (i < n && deleted[i]) || (j < m && inserted[j]) {
                while i < n, deleted[i] { i += 1 }
                while j < m, inserted[j] { j += 1 }
            }
            result.append(.changed(left: si..<i, right: sj..<j))
        }
    }
    return result
}

/// The full result of comparing two texts line by line, ready for side-by-side display.
public struct LineComparison {
    public let blocks: [DiffBlock]
    public let hunks: [DiffHunk]
    public let rows: [AlignedRow]

    public init(left: [String], right: [String]) {
        blocks = diffLines(left, right)
        var hunks: [DiffHunk] = []
        var rows: [AlignedRow] = []
        rows.reserveCapacity(max(left.count, right.count))
        for block in blocks {
            switch block {
            case let .equal(l, r):
                for k in 0..<l.count {
                    rows.append(AlignedRow(left: l.lowerBound + k, right: r.lowerBound + k, hunk: nil))
                }
            case let .changed(l, r):
                let start = rows.count
                let index = hunks.count
                for k in 0..<max(l.count, r.count) {
                    rows.append(AlignedRow(
                        left: k < l.count ? l.lowerBound + k : nil,
                        right: k < r.count ? r.lowerBound + k : nil,
                        hunk: index))
                }
                hunks.append(DiffHunk(left: l, right: r, rows: start..<rows.count))
            }
        }
        self.hunks = hunks
        self.rows = rows
    }
}

/// Splits text into lines on "\n". Text ending in a newline gets a final empty line,
/// matching how a text view shows it.
public func splitLines(_ text: String) -> [String] {
    text.components(separatedBy: "\n")
}
