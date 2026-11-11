import AppKit
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
    static let detectRenamesKey = "folder.detectRenames"

    static var detectRenames: Bool { UserDefaults.standard.bool(forKey: detectRenamesKey) }

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
        Picker("Whitespace", selection: $whitespace) {
            Text("Compare").tag(CompareOptions.Whitespace.compare.rawValue)
            Text("Ignore Amount").tag(CompareOptions.Whitespace.ignoreChange.rawValue)
            Text("Ignore All").tag(CompareOptions.Whitespace.ignoreAll.rawValue)
        }
        Toggle("Ignore Case", isOn: $ignoreCase)
        Toggle("Ignore Blank Lines", isOn: $ignoreBlankLines)
        Toggle("Ignore Line Ending Differences", isOn: $ignoreLineEndings)
        Toggle("Detect Moved Lines", isOn: $detectMovedBlocks)
    }
}

/// Options that only apply to folder comparisons.
struct FolderOptionControls: View {
    @AppStorage(CompareSettings.detectRenamesKey) private var detectRenames = false

    var body: some View {
        Toggle("Detect Renamed and Moved Files", isOn: $detectRenames)
    }
}

/// Toolbar menu with the compare options.
struct CompareOptionsMenu: View {
    var body: some View {
        Menu {
            CompareOptionControls()
        } label: {
            Label("Compare Options", systemImage: "slider.horizontal.3")
        }
        .help("Compare Options")
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Language") {
                LanguagePicker()
            }
            Section("Windows") {
                TabsToggle()
            }
            Section("Compare") {
                CompareOptionControls()
                FolderOptionControls()
            }
            EditorSettingsSection()
            Section {
                LineFilterEditor()
            } header: {
                Text("Line Filters")
            } footer: {
                Text("One regular expression per line. A difference is ignored when all of its lines match one of them. Example: ^\\s*// Generated:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Ignored differences are not counted and are shown in a pale color. Moved lines are shown in orange.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
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

/// Chooses the app's language. macOS reads it at launch, so a change needs a restart.
private struct LanguagePicker: View {
    @State private var choice = LanguageSetting.current
    private let launchChoice = LanguageSetting.current

    var body: some View {
        Picker("Language", selection: $choice) {
            Text("Same as System").tag(LanguageSetting.system)
            Text(verbatim: "English").tag(LanguageSetting.english)
            Text(verbatim: "日本語").tag(LanguageSetting.japanese)
        }
        .onChange(of: choice) { _, new in LanguageSetting.current = new }
        if choice != launchChoice {
            HStack {
                Text("Restart MacMerge to change the language.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restart Now") { LanguageSetting.relaunch() }
            }
            .font(.callout)
        }
    }
}

enum LanguageSetting: String {
    case system, english = "en", japanese = "ja"

    static var current: LanguageSetting {
        get {
            guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
                  let first = list.first else { return .system }
            return first.hasPrefix("ja") ? .japanese : .english
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// Starts a new copy of the app and quits this one.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}

private struct TabsToggle: View {
    @AppStorage(WindowSettings.tabsKey) private var opensInTabs = true

    var body: some View {
        Toggle("Open comparisons as tabs in one window", isOn: $opensInTabs)
            .onChange(of: opensInTabs) { _, _ in WindowSettings.applySystemPreference() }
        Text("Turn this off to open each comparison in its own window.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
