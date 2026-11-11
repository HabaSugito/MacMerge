import AppKit
import SwiftUI

/// Diff colors. Light mode uses WinMerge's default scheme; dark mode uses darker equivalents.
enum DiffColors {
    static var changed: NSColor { ColorOverrides.color("changed") ?? default_changed }
    static let default_changed = dynamic(light: (239, 203, 5), dark: (110, 90, 20))
    static var selected: NSColor { ColorOverrides.color("selected") ?? default_selected }
    static let default_selected = dynamic(light: (239, 119, 116), dark: (130, 50, 55))
    static let ghost = dynamic(light: (192, 192, 192), dark: (62, 62, 66))
    static let selectedGhost = dynamic(light: (240, 192, 192), dark: (85, 55, 58))
    static var word: NSColor { ColorOverrides.color("word") ?? default_word }
    static let default_word = dynamic(light: (241, 226, 173), dark: (165, 135, 40))
    static let selectedWord = dynamic(light: (255, 160, 160), dark: (190, 80, 85))
    static let ignored = dynamic(light: (251, 242, 191), dark: (58, 52, 30))
    static let ignoredGhost = dynamic(light: (233, 233, 233), dark: (48, 48, 50))
    static var moved: NSColor { ColorOverrides.color("moved") ?? default_moved }
    static let default_moved = dynamic(light: (228, 155, 82), dark: (120, 75, 35))
    static let selectedMoved = dynamic(light: (248, 112, 78), dark: (150, 60, 40))
    /// Three-way changes that can be merged automatically (one side only, or the same on both).
    static var mergeable: NSColor { ColorOverrides.color("mergeable") ?? default_mergeable }
    static let default_mergeable = dynamic(light: (190, 225, 250), dark: (35, 70, 100))
    static let selectedMergeable = dynamic(light: (120, 185, 240), dark: (50, 100, 150))
    static let mergeableWord = dynamic(light: (140, 195, 245), dark: (55, 105, 150))
    static let selectedMergeableWord = dynamic(light: (190, 225, 255), dark: (80, 135, 190))
    static let gutter = NSColor(name: nil) { $0.isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.95, alpha: 1) }

    static func defaultColor(_ name: String) -> NSColor {
        switch name {
        case "changed": return default_changed
        case "selected": return default_selected
        case "word": return default_word
        case "moved": return default_moved
        default: return default_mergeable
        }
    }

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.isDark ? dark : light
            return NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
