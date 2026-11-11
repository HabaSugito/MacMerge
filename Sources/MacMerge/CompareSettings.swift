import DiffCore
import SwiftUI

/// Compare options stored in user defaults. Views bind to the keys with @AppStorage;
/// open comparisons re-read them when they change.
enum CompareSettings {
    static let whitespaceKey = "compare.whitespace"
    static let ignoreCaseKey = "compare.ignoreCase"
    static let ignoreBlankLinesKey = "compare.ignoreBlankLines"
    static let ignoreLineEndingsKey = "compare.ignoreLineEndings"
    static let fileFilterKey = "folder.fileFilter"

    static var options: CompareOptions {
        let d = UserDefaults.standard
        return CompareOptions(
            whitespace: CompareOptions.Whitespace(rawValue: d.string(forKey: whitespaceKey) ?? "") ?? .compare,
            ignoreCase: d.bool(forKey: ignoreCaseKey),
            ignoreBlankLines: d.bool(forKey: ignoreBlankLinesKey),
            ignoreLineEndings: d.bool(forKey: ignoreLineEndingsKey))
    }

    static var fileFilter: String {
        UserDefaults.standard.string(forKey: fileFilterKey) ?? ""
    }
}

/// The compare option controls, used in the toolbar menu and the settings window.
struct CompareOptionControls: View {
    @AppStorage(CompareSettings.whitespaceKey) private var whitespace = CompareOptions.Whitespace.compare.rawValue
    @AppStorage(CompareSettings.ignoreCaseKey) private var ignoreCase = false
    @AppStorage(CompareSettings.ignoreBlankLinesKey) private var ignoreBlankLines = false
    @AppStorage(CompareSettings.ignoreLineEndingsKey) private var ignoreLineEndings = false

    var body: some View {
        Picker("空白", selection: $whitespace) {
            Text("比較する").tag(CompareOptions.Whitespace.compare.rawValue)
            Text("量の違いを無視").tag(CompareOptions.Whitespace.ignoreChange.rawValue)
            Text("すべて無視").tag(CompareOptions.Whitespace.ignoreAll.rawValue)
        }
        Toggle("大文字と小文字を無視", isOn: $ignoreCase)
        Toggle("空行を無視", isOn: $ignoreBlankLines)
        Toggle("改行コードの違いを無視", isOn: $ignoreLineEndings)
    }
}

/// Toolbar menu with the compare options.
struct CompareOptionsMenu: View {
    var body: some View {
        Menu {
            CompareOptionControls()
        } label: {
            Label("比較オプション", systemImage: "slider.horizontal.3")
        }
        .help("比較オプション")
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("比較") {
                CompareOptionControls()
            }
            Section {
                Text("無視した差分は差分として数えず、薄い色で表示します。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
