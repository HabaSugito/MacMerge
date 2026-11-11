import Foundation

/// Which differences count. Lines that differ only in ignored ways are matched as equal
/// and shown as "ignored" differences instead of real ones.
public struct CompareOptions: Equatable {
    public enum Whitespace: String, CaseIterable {
        /// Every whitespace difference counts.
        case compare
        /// Runs of spaces are treated as one space, and trailing spaces are ignored.
        case ignoreChange
        /// All whitespace is ignored.
        case ignoreAll
    }

    public var whitespace: Whitespace
    public var ignoreCase: Bool
    public var ignoreBlankLines: Bool
    /// Treat files that differ only in CRLF/LF/CR as identical in folder comparisons.
    public var ignoreLineEndings: Bool
    /// Show lines that moved to another place in their own color instead of as plain changes.
    public var detectMovedBlocks: Bool
    /// Regular expressions. A difference made only of lines matching one of them is ignored.
    public var lineFilters: [String]

    public init(whitespace: Whitespace = .compare, ignoreCase: Bool = false, ignoreBlankLines: Bool = false,
                ignoreLineEndings: Bool = false, detectMovedBlocks: Bool = false, lineFilters: [String] = []) {
        self.whitespace = whitespace
        self.ignoreCase = ignoreCase
        self.ignoreBlankLines = ignoreBlankLines
        self.ignoreLineEndings = ignoreLineEndings
        self.detectMovedBlocks = detectMovedBlocks
        self.lineFilters = lineFilters
    }

    /// Compiled line filters. Patterns that are not valid regular expressions are skipped.
    func compiledLineFilters() -> [NSRegularExpression] {
        lineFilters.compactMap { pattern in
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : try? NSRegularExpression(pattern: trimmed, options: ignoreCase ? [.caseInsensitive] : [])
        }
    }

    public static let standard = CompareOptions()

    var changesLineKeys: Bool { whitespace != .compare || ignoreCase }

    /// The form of a line that is actually compared.
    func key(_ line: String) -> String {
        guard changesLineKeys else { return line }
        var s = line
        if ignoreCase { s = s.lowercased() }
        switch whitespace {
        case .compare:
            break
        case .ignoreChange:
            var out = ""
            var inSpace = false
            for c in s {
                if c.isWhitespace {
                    if !inSpace { out.append(" ") }
                    inSpace = true
                } else {
                    out.append(c)
                    inSpace = false
                }
            }
            while out.last == " " { out.removeLast() }
            s = out
        case .ignoreAll:
            s.removeAll { $0.isWhitespace }
        }
        return s
    }

    /// The form of an inline token that is compared, or nil to leave the token out entirely.
    func tokenKey(_ token: Substring) -> Substring? {
        let isSpace = token.first?.isWhitespace ?? false
        if isSpace {
            switch whitespace {
            case .compare: return token
            case .ignoreChange: return " "
            case .ignoreAll: return nil
            }
        }
        return ignoreCase ? Substring(token.lowercased()) : token
    }
}

/// A WinMerge-style file mask such as `*.swift;*.txt;!*.o;!build/`.
/// Plain patterns choose which files are compared; `!` patterns exclude files,
/// and `!` patterns ending in `/` or `\` exclude folders.
public struct FileFilter: Equatable {
    public private(set) var includes: [String] = []
    public private(set) var excludes: [String] = []
    public private(set) var excludedFolders: [String] = []

    public init(_ text: String) {
        let parts = text.split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts where !part.isEmpty {
            var pattern = part
            let exclude = pattern.hasPrefix("!")
            if exclude { pattern.removeFirst() }
            let isFolder = pattern.hasSuffix("/") || pattern.hasSuffix("\\")
            if isFolder { pattern.removeLast() }
            if pattern == "*.*" { pattern = "*" }
            guard !pattern.isEmpty else { continue }
            if exclude {
                if isFolder { excludedFolders.append(pattern) } else { excludes.append(pattern) }
            } else if !isFolder {
                includes.append(pattern)
            }
        }
    }

    public static let all = FileFilter("")

    public var isEmpty: Bool { includes.isEmpty && excludes.isEmpty && excludedFolders.isEmpty }

    public func includesFile(named name: String) -> Bool {
        if excludes.contains(where: { matches($0, name) }) { return false }
        return includes.isEmpty || includes.contains { matches($0, name) }
    }

    public func includesFolder(named name: String) -> Bool {
        !excludedFolders.contains { matches($0, name) }
    }

    private func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, FNM_CASEFOLD) == 0
    }
}
