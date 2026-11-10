import Foundation

public enum InlineGranularity {
    case character
    case word
}

/// Finds which parts of two lines differ. Ranges are UTF-16 offsets within each line,
/// so they can be used directly with NSString and text views.
public func inlineDifferences(_ a: String, _ b: String, granularity: InlineGranularity = .word) -> (left: [NSRange], right: [NSRange]) {
    if a == b { return ([], []) }
    let ta = tokenize(a, granularity), tb = tokenize(b, granularity)
    var interner = Interner<Substring>()
    let ia = ta.map { interner.id($0.text) }
    let ib = tb.map { interner.id($0.text) }
    let diff = MyersDiff(ia, ib)
    return (ranges(ta, diff.deleted), ranges(tb, diff.inserted))
}

private struct Token {
    var text: Substring
    var utf16Start: Int
    var utf16Length: Int
}

private enum CharClass { case word, space, other }

private func charClass(_ c: Character) -> CharClass {
    if c.isWhitespace { return .space }
    if c == "_" { return .word }
    if c.isLetter || c.isNumber {
        // Japanese and Chinese text has no spaces, so treat each such character as its own word.
        if let s = c.unicodeScalars.first, isCJK(s) { return .other }
        return .word
    }
    return .other
}

private func isCJK(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0xAC00...0xD7AF:
        return true
    default:
        return false
    }
}

private func tokenize(_ s: String, _ granularity: InlineGranularity) -> [Token] {
    var tokens: [Token] = []
    var index = s.startIndex
    var offset = 0
    while index < s.endIndex {
        let c = s[index]
        let cls = charClass(c)
        var end = s.index(after: index)
        var length = c.utf16.count
        if granularity == .word, cls != .other {
            while end < s.endIndex, charClass(s[end]) == cls {
                length += s[end].utf16.count
                end = s.index(after: end)
            }
        }
        tokens.append(Token(text: s[index..<end], utf16Start: offset, utf16Length: length))
        offset += length
        index = end
    }
    return tokens
}

private func ranges(_ tokens: [Token], _ changed: [Bool]) -> [NSRange] {
    var result: [NSRange] = []
    for (token, isChanged) in zip(tokens, changed) where isChanged {
        if let last = result.last, last.location + last.length == token.utf16Start {
            result[result.count - 1].length += token.utf16Length
        } else {
            result.append(NSRange(location: token.utf16Start, length: token.utf16Length))
        }
    }
    return result
}
