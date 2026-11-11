import Foundation

/// Compares two changed versions (left and right) against their common base (middle),
/// the way diff3 and WinMerge's 3-way compare do.
public struct ThreeWayComparison {
    public let hunks: [DiffHunk]
    public let rows: [AlignedRow]

    public init(left: [String], middle base: [String], right: [String], options: CompareOptions = .standard) {
        let key: (String) -> String = options.changesLineKeys ? options.key : { $0 }
        let baseKeys = base.map(key), leftKeys = left.map(key), rightKeys = right.map(key)
        let toLeft = Self.matches(baseKeys, leftKeys)
        let toRight = Self.matches(baseKeys, rightKeys)

        var hunks: [DiffHunk] = []
        var rows: [AlignedRow] = []
        var b = 0, l = 0, r = 0
        let nb = base.count, nl = left.count, nr = right.count

        func emitUnstable(_ bEnd: Int, _ lEnd: Int, _ rEnd: Int) {
            let br = b..<bEnd, lr = l..<lEnd, rr = r..<rEnd
            guard !br.isEmpty || !lr.isEmpty || !rr.isEmpty else { return }
            let leftSame = Array(leftKeys[lr]) == Array(baseKeys[br])
            let rightSame = Array(rightKeys[rr]) == Array(baseKeys[br])
            let kind: DiffHunk.Kind
            if leftSame && rightSame { kind = .both } // only ignored differences
            else if rightSame { kind = .leftOnly }
            else if leftSame { kind = .rightOnly }
            else if Array(leftKeys[lr]) == Array(rightKeys[rr]) { kind = .both }
            else { kind = .conflict }

            let start = rows.count
            let isIgnored = leftSame && rightSame
            let index = isIgnored ? nil : hunks.count
            for k in 0..<max(br.count, lr.count, rr.count) {
                rows.append(AlignedRow(
                    left: k < lr.count ? lr.lowerBound + k : nil,
                    right: k < rr.count ? rr.lowerBound + k : nil,
                    middle: k < br.count ? br.lowerBound + k : nil,
                    hunk: index, isIgnored: isIgnored))
            }
            if !isIgnored {
                hunks.append(DiffHunk(left: lr, right: rr, middle: br, rows: start..<rows.count, kind: kind))
            }
            b = bEnd; l = lEnd; r = rEnd
        }

        while b < nb || l < nl || r < nr {
            // A stable run: base lines matched to the current position on both sides.
            var k = 0
            while b + k < nb, toLeft[b + k] == l + k, toRight[b + k] == r + k { k += 1 }
            if k > 0 {
                for i in 0..<k {
                    let ignored = options.changesLineKeys && (left[l + i] != base[b + i] || right[r + i] != base[b + i])
                    rows.append(AlignedRow(left: l + i, right: r + i, middle: b + i, hunk: nil, isIgnored: ignored))
                }
                b += k; l += k; r += k
                continue
            }
            // An unstable run lasts until the next base line that both sides kept.
            if let next = (b..<nb).first(where: { toLeft[$0] != nil && toRight[$0] != nil }) {
                emitUnstable(next, toLeft[next]!, toRight[next]!)
            } else {
                emitUnstable(nb, nl, nr)
            }
        }
        self.hunks = hunks
        self.rows = rows
    }

    /// For each base line, the index of the matching line in `other`, or nil.
    private static func matches(_ base: [String], _ other: [String]) -> [Int?] {
        var result = [Int?](repeating: nil, count: base.count)
        for block in diffLines(base, other) {
            if case let .equal(bRange, oRange) = block {
                for k in 0..<bRange.count { result[bRange.lowerBound + k] = oRange.lowerBound + k }
            }
        }
        return result
    }
}

/// A file with Git-style conflict markers, split into its two sides and the base.
public struct ConflictFile: Equatable {
    public var ours: String
    public var base: String
    public var theirs: String
    public var oursLabel: String
    public var theirsLabel: String
    public var conflictCount: Int

    /// Returns nil when the text has no conflict markers.
    public init?(text: String) {
        var ours: [String] = [], base: [String] = [], theirs: [String] = []
        var oursLabel = "", theirsLabel = ""
        enum Section { case outside, ours, base, theirs }
        var section = Section.outside
        var count = 0
        let lines = splitLines(text)
        for line in lines {
            if line.hasPrefix("<<<<<<<"), section == .outside {
                section = .ours; count += 1
                if oursLabel.isEmpty { oursLabel = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("|||||||"), section == .ours {
                section = .base
            } else if line.hasPrefix("======="), section == .ours || section == .base {
                section = .theirs
            } else if line.hasPrefix(">>>>>>>"), section == .theirs {
                section = .outside
                if theirsLabel.isEmpty { theirsLabel = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            } else {
                switch section {
                case .outside: ours.append(line); base.append(line); theirs.append(line)
                case .ours: ours.append(line)
                case .base: base.append(line)
                case .theirs: theirs.append(line)
                }
            }
        }
        guard count > 0, section == .outside else { return nil }
        self.ours = ours.joined(separator: "\n")
        self.base = base.joined(separator: "\n")
        self.theirs = theirs.joined(separator: "\n")
        self.oursLabel = oursLabel
        self.theirsLabel = theirsLabel
        conflictCount = count
    }
}
