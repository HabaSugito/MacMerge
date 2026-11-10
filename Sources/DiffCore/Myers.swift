/// Myers' O(ND) diff in linear space (divide and conquer on the "middle snake").
/// Works on integer sequences; callers map lines or tokens to integers first.
struct MyersDiff {
    private let a: [Int]
    private let b: [Int]
    /// `deleted[i]` is true when `a[i]` has no partner in `b`.
    private(set) var deleted: [Bool]
    /// `inserted[j]` is true when `b[j]` has no partner in `a`.
    private(set) var inserted: [Bool]

    init(_ a: [Int], _ b: [Int]) {
        self.a = a
        self.b = b
        deleted = Array(repeating: false, count: a.count)
        inserted = Array(repeating: false, count: b.count)
        compare(0, a.count, 0, b.count)
    }

    private mutating func compare(_ aLo0: Int, _ aHi0: Int, _ bLo0: Int, _ bHi0: Int) {
        var aLo = aLo0, aHi = aHi0, bLo = bLo0, bHi = bHi0
        while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] { aLo += 1; bLo += 1 }
        while aLo < aHi, bLo < bHi, a[aHi - 1] == b[bHi - 1] { aHi -= 1; bHi -= 1 }

        if aLo == aHi {
            for j in bLo..<bHi { inserted[j] = true }
            return
        }
        if bLo == bHi {
            for i in aLo..<aHi { deleted[i] = true }
            return
        }
        let n = aHi - aLo, m = bHi - bLo
        if let (x, y) = middleSnake(aLo, n, bLo, m), !(x == 0 && y == 0), !(x == n && y == m) {
            compare(aLo, aLo + x, bLo, bLo + y)
            compare(aLo + x, aHi, bLo + y, bHi)
        } else {
            for i in aLo..<aHi { deleted[i] = true }
            for j in bLo..<bHi { inserted[j] = true }
        }
    }

    /// Finds a point on an optimal edit path, searching forward and backward at once.
    /// Returns the split point relative to (aLo, bLo), or nil when the ranges share nothing.
    private func middleSnake(_ aLo: Int, _ n: Int, _ bLo: Int, _ m: Int) -> (Int, Int)? {
        let maxD = (n + m + 1) / 2
        let offset = maxD
        let length = 2 * maxD + 2
        var v1 = [Int](repeating: -1, count: length)
        var v2 = [Int](repeating: -1, count: length)
        v1[offset + 1] = 0
        v2[offset + 1] = 0
        let delta = n - m
        let front = delta % 2 != 0
        var k1start = 0, k1end = 0, k2start = 0, k2end = 0

        for d in 0..<maxD {
            var k1 = -d + k1start
            while k1 <= d - k1end {
                let k1Off = offset + k1
                var x1 = (k1 == -d || (k1 != d && v1[k1Off - 1] < v1[k1Off + 1])) ? v1[k1Off + 1] : v1[k1Off - 1] + 1
                var y1 = x1 - k1
                while x1 < n, y1 < m, a[aLo + x1] == b[bLo + y1] { x1 += 1; y1 += 1 }
                v1[k1Off] = x1
                if x1 > n {
                    k1end += 2
                } else if y1 > m {
                    k1start += 2
                } else if front {
                    let k2Off = offset + delta - k1
                    if k2Off >= 0, k2Off < length, v2[k2Off] != -1, x1 >= n - v2[k2Off] {
                        return (x1, y1)
                    }
                }
                k1 += 2
            }

            var k2 = -d + k2start
            while k2 <= d - k2end {
                let k2Off = offset + k2
                var x2 = (k2 == -d || (k2 != d && v2[k2Off - 1] < v2[k2Off + 1])) ? v2[k2Off + 1] : v2[k2Off - 1] + 1
                var y2 = x2 - k2
                while x2 < n, y2 < m, a[aLo + n - x2 - 1] == b[bLo + m - y2 - 1] { x2 += 1; y2 += 1 }
                v2[k2Off] = x2
                if x2 > n {
                    k2end += 2
                } else if y2 > m {
                    k2start += 2
                } else if !front {
                    let k1Off = offset + delta - k2
                    if k1Off >= 0, k1Off < length, v1[k1Off] != -1 {
                        let x1 = v1[k1Off]
                        let y1 = offset + x1 - k1Off
                        if x1 >= n - x2 { return (x1, y1) }
                    }
                }
                k2 += 2
            }
        }
        return nil
    }
}

/// Maps hashable items to small integers so the same item always gets the same number.
struct Interner<T: Hashable> {
    private var table: [T: Int] = [:]
    mutating func id(_ item: T) -> Int {
        if let id = table[item] { return id }
        let id = table.count
        table[item] = id
        return id
    }
}
