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
    /// Panes opened read-only, chosen in the open screen.
    var readOnlyLeft = false
    var readOnlyMiddle = false
    var readOnlyRight = false
    /// Folder comparisons: look into subfolders.
    var includeSubfolders = true

    init(left: URL, right: URL, middle: URL? = nil, output: URL? = nil, kind: Kind) {
        self.left = left
        self.right = right
        self.middle = middle
        self.output = output
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case left, right, middle, output, kind, readOnlyLeft, readOnlyMiddle, readOnlyRight, includeSubfolders
    }

    /// Reads targets saved by older versions too, which lack the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decode(URL.self, forKey: .left)
        right = try c.decode(URL.self, forKey: .right)
        middle = try c.decodeIfPresent(URL.self, forKey: .middle)
        output = try c.decodeIfPresent(URL.self, forKey: .output)
        kind = try c.decode(Kind.self, forKey: .kind)
        readOnlyLeft = try c.decodeIfPresent(Bool.self, forKey: .readOnlyLeft) ?? false
        readOnlyMiddle = try c.decodeIfPresent(Bool.self, forKey: .readOnlyMiddle) ?? false
        readOnlyRight = try c.decodeIfPresent(Bool.self, forKey: .readOnlyRight) ?? false
        includeSubfolders = try c.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? true
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
        if kind == .conflict { return L("\(left.lastPathComponent) (Conflict)") }
        if let middle { return "\(left.lastPathComponent) ↔ \(middle.lastPathComponent) ↔ \(right.lastPathComponent)" }
        return left.lastPathComponent == right.lastPathComponent
            ? left.lastPathComponent
            : "\(left.lastPathComponent) ↔ \(right.lastPathComponent)"
    }
}
