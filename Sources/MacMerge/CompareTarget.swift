import Foundation

/// What a comparison window shows. Used as the window's value so windows can be reopened.
struct CompareTarget: Codable, Hashable {
    enum Kind: String, Codable {
        case files
        case folders
        /// One file with Git conflict markers, shown as its two sides and the result.
        case conflict
    }

    var left: URL
    var right: URL
    /// Three-way compare: the common base, shown in the middle.
    var middle: URL?
    /// Three-way compare: where the merged middle pane is saved (e.g. git mergetool's MERGED).
    var output: URL?
    var kind: Kind

    init(left: URL, right: URL, middle: URL? = nil, output: URL? = nil, kind: Kind) {
        self.left = left
        self.right = right
        self.middle = middle
        self.output = output
        self.kind = kind
    }

    init(left: URL, right: URL, isFolder: Bool) {
        self.init(left: left, right: right, kind: isFolder ? .folders : .files)
    }

    static func conflict(_ url: URL) -> CompareTarget {
        CompareTarget(left: url, right: url, middle: url, output: url, kind: .conflict)
    }

    var isFolder: Bool { kind == .folders }
    var isThreeWay: Bool { middle != nil }

    var title: String {
        if kind == .conflict { return "\(left.lastPathComponent)（コンフリクト）" }
        if let middle { return "\(left.lastPathComponent) ↔ \(middle.lastPathComponent) ↔ \(right.lastPathComponent)" }
        return left.lastPathComponent == right.lastPathComponent
            ? left.lastPathComponent
            : "\(left.lastPathComponent) ↔ \(right.lastPathComponent)"
    }
}
