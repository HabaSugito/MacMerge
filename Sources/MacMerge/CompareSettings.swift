import DiffCore
import SwiftUI

/// Compare options stored in user defaults. Views bind to the keys with @AppStorage;
/// open comparisons re-read them when they change.
enum CompareSettings {
    static let whitespaceKey = "compare.whitespace"
    static let ignoreCaseKey = "compare.ignoreCase"
    static let ignoreBlankLinesKey = "compare.ignoreBlankLines"
    static let ignoreLineEndingsKey = "compare.ignoreLineEndings"
    static let detectMovedBlocksKey = "compare.detectMovedBlocks"
    static let lineFiltersKey = "compare.lineFilters"
    static let fileFilterKey = "folder.fileFilter"

    static var options: CompareOptions {
        let d = UserDefaults.standard
        return CompareOptions(
            whitespace: CompareOptions.Whitespace(rawValue: d.string(forKey: whitespaceKey) ?? "") ?? .compare,
            ignoreCase: d.bool(forKey: ignoreCaseKey),
            ignoreBlankLines: d.bool(forKey: ignoreBlankLinesKey),
            ignoreLineEndings: d.bool(forKey: ignoreLineEndingsKey),
            detectMovedBlocks: d.bool(forKey: detectMovedBlocksKey),
            lineFilters: (d.string(forKey: lineFiltersKey) ?? "").components(separatedBy: "\n"))
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
    @AppStorage(CompareSettings.detectMovedBlocksKey) private var detectMovedBlocks = false

    var body: some View {
        Picker("空白", selection: $whitespace) {
            Text("比較する").tag(CompareOptions.Whitespace.compare.rawValue)
            Text("量の違いを無視").tag(CompareOptions.Whitespace.ignoreChange.rawValue)
            Text("すべて無視").tag(CompareOptions.Whitespace.ignoreAll.rawValue)
        }
        Toggle("大文字と小文字を無視", isOn: $ignoreCase)
        Toggle("空行を無視", isOn: $ignoreBlankLines)
        Toggle("改行コードの違いを無視", isOn: $ignoreLineEndings)
        Toggle("移動した行を検出", isOn: $detectMovedBlocks)
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
                LineFilterEditor()
            } header: {
                Text("行フィルタ")
            } footer: {
                Text("1行に1つずつ正規表現を書きます。差分の行がすべてどれかに当てはまるとき、その差分を無視します。例: ^\\s*// Generated:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("無視した差分は差分として数えず、薄い色で表示します。移動した行はオレンジで表示します。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LineFilterEditor: View {
    @AppStorage(CompareSettings.lineFiltersKey) private var stored = ""
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .frame(height: 80)
            .onAppear { text = stored }
            // Apply when typing pauses, so open comparisons do not recompare on every key.
            .onChange(of: text) { _, new in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if text == new, stored != new { stored = new }
                }
            }
    }
}
