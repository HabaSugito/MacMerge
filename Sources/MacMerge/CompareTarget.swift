import Foundation

/// What a comparison window shows. Used as the window's value so windows can be reopened.
struct CompareTarget: Codable, Hashable {
    var left: URL
    var right: URL
    var isFolder: Bool

    var title: String {
        left.lastPathComponent == right.lastPathComponent
            ? left.lastPathComponent
            : "\(left.lastPathComponent) ↔ \(right.lastPathComponent)"
    }
}
