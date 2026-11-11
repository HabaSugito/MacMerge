import AppKit

/// Simple syntax coloring for common languages: keywords, strings, comments and numbers.
/// It is regular-expression based, which is enough to make code easier to read in a diff.
struct SyntaxHighlighter {
    private let regex: NSRegularExpression
    private let keywords: Set<String>

    static let keywordColor = dynamic(light: (155, 35, 147), dark: (252, 95, 163))
    static let stringColor = dynamic(light: (196, 26, 22), dark: (252, 106, 93))
    static let commentColor = dynamic(light: (93, 108, 121), dark: (108, 121, 134))
    static let numberColor = dynamic(light: (28, 0, 207), dark: (208, 191, 105))

    /// The highlighter for a file name, or nil for plain text and unknown types.
    static func forFile(_ url: URL?) -> SyntaxHighlighter? {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else { return nil }
        return languages.first { $0.extensions.contains(ext) }.map(SyntaxHighlighter.init)
    }

    private init(_ lang: Language) {
        keywords = Set(lang.keywords.split(separator: " ").map(String.init))
        var parts: [String] = []
        if let block = lang.blockComment {
            parts.append("(?<comment>" + NSRegularExpression.escapedPattern(for: block.0) + "[\\s\\S]*?(?:" + NSRegularExpression.escapedPattern(for: block.1) + "|$))")
        }
        if let line = lang.lineComment {
            parts.append("(?<line>" + NSRegularExpression.escapedPattern(for: line) + "[^\\n]*)")
        }
        parts.append("(?<string>\"(?:[^\"\\\\\\n]|\\\\.)*\"" + (lang.singleQuoteStrings ? "|'(?:[^'\\\\\\n]|\\\\.)*'" : "") + ")")
        parts.append("(?<number>\\b(?:0x[0-9a-fA-F_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b)")
        parts.append("(?<word>\\b[A-Za-z_][A-Za-z0-9_]*\\b)")
        regex = try! NSRegularExpression(pattern: parts.joined(separator: "|"))
    }

    /// Colors `storage`'s text. Only foreground colors change.
    func apply(to storage: NSTextStorage) {
        let text = storage.string
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
        regex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            if match.range(withName: "comment").location != NSNotFound || match.range(withName: "line").location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: Self.commentColor, range: match.range)
            } else if match.range(withName: "string").location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: Self.stringColor, range: match.range)
            } else if match.range(withName: "number").location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: Self.numberColor, range: match.range)
            } else if keywords.contains((text as NSString).substring(with: match.range)) {
                storage.addAttribute(.foregroundColor, value: Self.keywordColor, range: match.range)
            }
        }
    }

    private struct Language {
        var extensions: Set<String>
        var keywords: String
        var lineComment: String?
        var blockComment: (String, String)?
        var singleQuoteStrings = true
    }

    private static let cKeywords = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false NULL nullptr class public private protected virtual template typename namespace using new delete this throw try catch include define ifdef ifndef endif"

    private static let languages: [Language] = [
        Language(extensions: ["swift"], keywords: "actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is lazy let mutating nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while", lineComment: "//", blockComment: ("/*", "*/"), singleQuoteStrings: false),
        Language(extensions: ["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm"], keywords: cKeywords, lineComment: "//", blockComment: ("/*", "*/")),
        Language(extensions: ["java", "kt", "kts", "scala", "cs"], keywords: "abstract break case catch class const continue default do else enum extends final finally for fun if implements import in instanceof interface is internal new null object override package private protected public return sealed static super switch this throw throws try val var void when while true false namespace using readonly async await", lineComment: "//", blockComment: ("/*", "*/")),
        Language(extensions: ["js", "jsx", "ts", "tsx", "mjs", "cjs"], keywords: "async await break case catch class const continue default delete do else export extends false finally for from function if import in instanceof interface let new null of return static super switch this throw true try type typeof undefined var void while yield", lineComment: "//", blockComment: ("/*", "*/")),
        Language(extensions: ["go"], keywords: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil", lineComment: "//", blockComment: ("/*", "*/")),
        Language(extensions: ["rs"], keywords: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while", lineComment: "//", blockComment: ("/*", "*/")),
        Language(extensions: ["py"], keywords: "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield", lineComment: "#"),
        Language(extensions: ["rb"], keywords: "alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield", lineComment: "#"),
        Language(extensions: ["sh", "bash", "zsh"], keywords: "if then else elif fi case esac for while until do done in function return local export readonly", lineComment: "#"),
        Language(extensions: ["yml", "yaml", "toml", "ini", "conf"], keywords: "true false null yes no", lineComment: "#"),
        Language(extensions: ["json"], keywords: "true false null"),
        Language(extensions: ["php"], keywords: "abstract and array as break case catch class const continue declare default do echo else elseif extends final for foreach function global if implements include interface namespace new null private protected public require return static switch throw trait try use var while true false", lineComment: "//", blockComment: ("/*", "*/")),
        Language(extensions: ["sql"], keywords: "select from where insert into values update set delete create table drop alter index join left right inner outer on group by order having limit and or not null as distinct union SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE DROP ALTER INDEX JOIN LEFT RIGHT INNER OUTER ON GROUP BY ORDER HAVING LIMIT AND OR NOT NULL AS DISTINCT UNION", lineComment: "--", blockComment: ("/*", "*/")),
        Language(extensions: ["html", "htm", "xml", "plist", "svg"], keywords: "", blockComment: ("<!--", "-->")),
        Language(extensions: ["css", "scss", "less"], keywords: "important", blockComment: ("/*", "*/")),
    ]

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.isDark ? dark : light
            return NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
    }
}
