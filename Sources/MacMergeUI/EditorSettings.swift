import AppKit
import SwiftUI

/// Editor appearance stored in user defaults: font, tab width, syntax colors and diff colors.
enum EditorSettings {
    static let fontNameKey = "editor.fontName"
    static let fontSizeKey = "editor.fontSize"
    static let tabWidthKey = "editor.tabWidth"
    static let syntaxKey = "editor.syntaxHighlighting"

    /// The editor font. An empty name means the system monospaced font.
    static var font: NSFont {
        let d = UserDefaults.standard
        let size = d.object(forKey: fontSizeKey) as? Double ?? 13
        if let name = d.string(forKey: fontNameKey), !name.isEmpty, let font = NSFont(name: name, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var tabWidth: Int {
        max(1, min(16, UserDefaults.standard.object(forKey: tabWidthKey) as? Int ?? 4))
    }

    static var syntaxHighlighting: Bool {
        UserDefaults.standard.object(forKey: syntaxKey) as? Bool ?? true
    }

    /// Monospaced font families installed on this Mac, for the font menu.
    static var monospacedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family),
                  let first = members.first?.first as? String,
                  let font = NSFont(name: first, size: 13) else { return false }
            return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
    }

    /// The PostScript name of the regular face of a font family.
    static func regularFace(of family: String) -> String? {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?.fontName
    }
}

/// User-chosen diff colors. A color the user has not changed keeps its light/dark default.
enum ColorOverrides {
    static func key(_ name: String) -> String { "color." + name }

    static func color(_ name: String) -> NSColor? {
        guard let hex = UserDefaults.standard.string(forKey: key(name)), hex.count == 7,
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func set(_ name: String, _ color: NSColor?) {
        guard let c = color?.usingColorSpace(.sRGB) else {
            UserDefaults.standard.removeObject(forKey: key(name))
            return
        }
        let hex = String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
        UserDefaults.standard.set(hex, forKey: key(name))
    }

    static let editable: [(name: String, title: LocalizedStringKey)] = [
        ("changed", "Difference"),
        ("selected", "Selected Difference"),
        ("word", "Difference Within a Line"),
        ("moved", "Moved Lines"),
        ("mergeable", "Mergeable Difference (3-way)"),
    ]

    static func resetAll() {
        for item in editable { set(item.name, nil) }
    }
}

/// Settings for the editor: font, tabs, syntax colors and diff colors.
struct EditorSettingsSection: View {
    @AppStorage(EditorSettings.fontNameKey) private var fontName = ""
    @AppStorage(EditorSettings.fontSizeKey) private var fontSize = 13.0
    @AppStorage(EditorSettings.tabWidthKey) private var tabWidth = 4
    @AppStorage(EditorSettings.syntaxKey) private var syntax = true
    @State private var colorRefresh = 0

    var body: some View {
        Section("Editor") {
            Picker("Font", selection: $fontName) {
                Text("System Monospaced").tag("")
                ForEach(EditorSettings.monospacedFamilies, id: \.self) { family in
                    Text(verbatim: family).tag(EditorSettings.regularFace(of: family) ?? family)
                }
            }
            Stepper(value: $fontSize, in: 8...36, step: 1) {
                Text("Font Size: \(Int(fontSize))")
            }
            Stepper(value: $tabWidth, in: 1...16) {
                Text("Tab Width: \(tabWidth)")
            }
            Toggle("Syntax Highlighting", isOn: $syntax)
        }
        Section("Colors") {
            ForEach(ColorOverrides.editable, id: \.name) { item in
                ColorPicker(item.title, selection: Binding(
                    get: { Color(nsColor: ColorOverrides.color(item.name) ?? DiffColors.defaultColor(item.name)) },
                    set: { ColorOverrides.set(item.name, NSColor($0)); colorRefresh += 1 }),
                    supportsOpacity: false)
            }
            .id(colorRefresh)
            Button("Restore Default Colors") {
                ColorOverrides.resetAll()
                colorRefresh += 1
            }
        }
    }
}
