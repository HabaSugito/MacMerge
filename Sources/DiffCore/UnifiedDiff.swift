import Foundation

/// Builds patches in the unified format that `patch` and `git apply` read.
public enum UnifiedDiff {
    /// A patch turning `oldText` into `newText`, or "" when they are equal.
    public static func make(oldName: String, newName: String, oldText: String, newText: String, context: Int = 3) -> String {
        let (old, oldEndsWithNewline) = contentLines(oldText)
        let (new, newEndsWithNewline) = contentLines(newText)
        // Mark a last line that has no newline, so "x" and "x\n" compare as different.
        let marker = "\u{0}"
        var oldKeys = old, newKeys = new
        if !oldEndsWithNewline, !oldKeys.isEmpty { oldKeys[oldKeys.count - 1] += marker }
        if !newEndsWithNewline, !newKeys.isEmpty { newKeys[newKeys.count - 1] += marker }

        enum Op { case same(Int, Int), removed(Int), added(Int) }
        var ops: [Op] = []
        for block in diffLines(oldKeys, newKeys) {
            switch block {
            case let .equal(l, r):
                for k in 0..<l.count { ops.append(.same(l.lowerBound + k, r.lowerBound + k)) }
            case let .changed(l, r):
                ops += l.map { .removed($0) }
                ops += r.map { .added($0) }
            }
        }
        func isChange(_ op: Op) -> Bool { if case .same = op { return false } else { return true } }
        guard ops.contains(where: isChange) else { return "" }

        var out = "--- \(oldName)\n+++ \(newName)\n"
        var i = 0
        while i < ops.count {
            guard let first = ops[i...].firstIndex(where: isChange) else { break }
            var last = first
            var j = first
            // Extend the hunk while the next change is within 2 × context lines.
            while j < ops.count {
                if isChange(ops[j]) { last = j }
                if j - last > 2 * context { break }
                j += 1
            }
            let start = max(i, first - context)
            let end = min(ops.count, last + context + 1)
            let slice = ops[start..<end]

            var oldBefore = 0, newBefore = 0
            for op in ops[..<start] {
                switch op {
                case .same: oldBefore += 1; newBefore += 1
                case .removed: oldBefore += 1
                case .added: newBefore += 1
                }
            }
            var oldCount = 0, newCount = 0
            var body = ""
            for op in slice {
                switch op {
                case let .same(l, _):
                    oldCount += 1; newCount += 1
                    body += " " + old[l] + "\n"
                    if !oldEndsWithNewline, l == old.count - 1 { body += "\\ No newline at end of file\n" }
                case let .removed(l):
                    oldCount += 1
                    body += "-" + old[l] + "\n"
                    if !oldEndsWithNewline, l == old.count - 1 { body += "\\ No newline at end of file\n" }
                case let .added(r):
                    newCount += 1
                    body += "+" + new[r] + "\n"
                    if !newEndsWithNewline, r == new.count - 1 { body += "\\ No newline at end of file\n" }
                }
            }
            out += "@@ -\(range(oldBefore, oldCount)) +\(range(newBefore, newCount)) @@\n" + body
            i = end
        }
        return out
    }

    private static func range(_ before: Int, _ count: Int) -> String {
        if count == 0 { return "\(before),0" }
        return count == 1 ? "\(before + 1)" : "\(before + 1),\(count)"
    }

    /// Lines of a text without the empty element `splitLines` adds after a final newline.
    static func contentLines(_ text: String) -> (lines: [String], endsWithNewline: Bool) {
        guard !text.isEmpty else { return ([], true) }
        var lines = splitLines(text)
        let ends = lines.last == ""
        if ends { lines.removeLast() }
        return (lines, ends)
    }
}
