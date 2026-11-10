import Foundation

/// One block of lines in a two-way comparison.
public enum DiffBlock: Equatable {
    case equal(left: Range<Int>, right: Range<Int>)
    case changed(left: Range<Int>, right: Range<Int>)
}

/// Compares two arrays of lines using a longest-common-subsequence table.
/// Placeholder implementation; a Myers diff will replace it for large files.
public func diffLines(_ a: [String], _ b: [String]) -> [DiffBlock] {
    let n = a.count, m = b.count
    var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
        }
    }
    var blocks: [DiffBlock] = []
    var i = 0, j = 0, ci = 0, cj = 0
    func flushChange() {
        if ci < i || cj < j { blocks.append(.changed(left: ci..<i, right: cj..<j)) }
    }
    while i < n || j < m {
        if i < n, j < m, a[i] == b[j] {
            flushChange()
            let si = i, sj = j
            while i < n, j < m, a[i] == b[j] { i += 1; j += 1 }
            blocks.append(.equal(left: si..<i, right: sj..<j))
            ci = i; cj = j
        } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
            j += 1
        } else {
            i += 1
        }
    }
    flushChange()
    return blocks
}
