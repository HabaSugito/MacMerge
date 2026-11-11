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
    /// The lines differ, but only in ways the compare options ignore.
    public var isIgnored: Bool

    public init(left: Int?, right: Int?, hunk: Int?, isIgnored: Bool = false) {
        self.left = left
        self.right = right
        self.hunk = hunk
        self.isIgnored = isIgnored
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

    public init(left: [String], right: [String], options: CompareOptions = .standard) {
        if options.changesLineKeys {
            blocks = diffLines(left.map(options.key), right.map(options.key))
        } else {
            blocks = diffLines(left, right)
        }
        var hunks: [DiffHunk] = []
        var rows: [AlignedRow] = []
        rows.reserveCapacity(max(left.count, right.count))
        for block in blocks {
            switch block {
            case let .equal(l, r):
                for k in 0..<l.count {
                    let li = l.lowerBound + k, ri = r.lowerBound + k
                    let ignored = options.changesLineKeys && left[li] != right[ri]
                    rows.append(AlignedRow(left: li, right: ri, hunk: nil, isIgnored: ignored))
                }
            case let .changed(l, r) where options.ignoreBlankLines
                && left[l].allSatisfy(isBlank) && right[r].allSatisfy(isBlank):
                // Only blank lines were added or removed.
                for k in 0..<max(l.count, r.count) {
                    rows.append(AlignedRow(
                        left: k < l.count ? l.lowerBound + k : nil,
                        right: k < r.count ? r.lowerBound + k : nil,
                        hunk: nil, isIgnored: true))
                }
            case let .changed(l, r):
                let start = rows.count
                let index = hunks.count
                for pair in pairLines(Array(left[l]), Array(right[r]), options: options) {
                    rows.append(AlignedRow(
                        left: pair.left.map { l.lowerBound + $0 },
                        right: pair.right.map { r.lowerBound + $0 },
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

private func isBlank(_ line: String) -> Bool {
    line.allSatisfy(\.isWhitespace)
}

/// Decides which lines of a changed block share a row. Similar lines are put side by side
/// (like WinMerge's "align similar lines"); the rest are paired in order.
func pairLines(_ a: [String], _ b: [String], options: CompareOptions) -> [(left: Int?, right: Int?)] {
    func inOrder(_ aRange: Range<Int>, _ bRange: Range<Int>) -> [(left: Int?, right: Int?)] {
        (0..<max(aRange.count, bRange.count)).map { k in
            (k < aRange.count ? aRange.lowerBound + k : nil, k < bRange.count ? bRange.lowerBound + k : nil)
        }
    }
    let n = a.count, m = b.count
    guard n > 0, m > 0, n != m || n > 1, n * m <= 2500 else { return inOrder(0..<n, 0..<m) }

    let ka = a.map { bigrams(options.key($0)) }, kb = b.map { bigrams(options.key($0)) }
    var sim = Array(repeating: Array(repeating: 0.0, count: m), count: n)
    for i in 0..<n { for j in 0..<m { sim[i][j] = dice(ka[i], kb[j]) } }

    // Best total similarity of matched pairs, keeping order on both sides.
    let threshold = 0.5
    var score = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
    for i in 1...n {
        for j in 1...m {
            var best = max(score[i - 1][j], score[i][j - 1])
            if sim[i - 1][j - 1] >= threshold { best = max(best, score[i - 1][j - 1] + sim[i - 1][j - 1]) }
            score[i][j] = best
        }
    }
    var matches: [(Int, Int)] = []
    var i = n, j = m
    while i > 0, j > 0 {
        if sim[i - 1][j - 1] >= threshold, score[i][j] == score[i - 1][j - 1] + sim[i - 1][j - 1] {
            matches.append((i - 1, j - 1)); i -= 1; j -= 1
        } else if score[i][j] == score[i - 1][j] {
            i -= 1
        } else {
            j -= 1
        }
    }
    matches.reverse()

    var result: [(left: Int?, right: Int?)] = []
    var ai = 0, bi = 0
    for (x, y) in matches {
        result += inOrder(ai..<x, bi..<y).map { ($0.left, $0.right) }
        result.append((x, y))
        ai = x + 1; bi = y + 1
    }
    result += inOrder(ai..<n, bi..<m)
    return result
}

private func bigrams(_ s: String) -> [String: Int] {
    let chars = Array(s.filter { !$0.isWhitespace })
    var counts: [String: Int] = [:]
    if chars.count == 1 { counts[String(chars[0]), default: 0] += 1 }
    for k in 0..<max(chars.count - 1, 0) { counts[String(chars[k...k + 1]), default: 0] += 1 }
    return counts
}

/// Dice similarity of two bigram multisets, from 0 (nothing shared) to 1 (identical).
private func dice(_ a: [String: Int], _ b: [String: Int]) -> Double {
    let total = a.values.reduce(0, +) + b.values.reduce(0, +)
    guard total > 0 else { return 0 }
    var shared = 0
    for (key, count) in a { shared += min(count, b[key] ?? 0) }
    return 2 * Double(shared) / Double(total)
}
