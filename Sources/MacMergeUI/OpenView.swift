import AppKit
import SwiftUI

/// The "select files or folders" tab, like WinMerge's Open view. Comparing turns this tab
/// into the comparison.
struct OpenView: View {
    @Binding var target: CompareTarget?
    @AppStorage("lastLeftPath") private var leftPath = ""
    @AppStorage("lastRightPath") private var rightPath = ""
    @AppStorage("lastMiddlePath") private var middlePath = ""
    @AppStorage("open.readOnlyLeft") private var readOnlyLeft = false
    @AppStorage("open.readOnlyMiddle") private var readOnlyMiddle = false
    @AppStorage("open.readOnlyRight") private var readOnlyRight = false
    @AppStorage("open.includeSubfolders") private var includeSubfolders = true
    @AppStorage(CompareSettings.fileFilterKey) private var filter = ""
    @State private var error: String?
    @ObservedObject private var recent = RecentComparisons.shared
    @ObservedObject private var history = PathHistory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Files or Folders")
                .font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                pathRow("Left", $leftPath, readOnly: $readOnlyLeft)
                pathRow("Middle", $middlePath, readOnly: $readOnlyMiddle, placeholder: "Optional: the base file for a 3-way comparison")
                pathRow("Right", $rightPath, readOnly: $readOnlyRight)
                GridRow {
                    Text("Filter")
                    ComboField(text: $filter, prompt: Text(verbatim: "*.*"), choices: FilterPresets.all)
                    Toggle("Include Subfolders", isOn: $includeSubfolders)
                        .gridCellColumns(2)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Button {
                    swap(&leftPath, &rightPath)
                    swap(&readOnlyLeft, &readOnlyRight)
                } label: {
                    Label("Swap Left and Right", systemImage: "arrow.left.arrow.right")
                }
                Spacer()
                Button("Compare") { compare() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(leftPath.isEmpty || rightPath.isEmpty)
            }
            if !recent.items.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Recent Comparisons").font(.headline)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recent.items.prefix(10), id: \.self) { item in
                        Button {
                            target = item
                        } label: {
                            HStack {
                                Image(systemName: item.isFolder ? "folder" : (item.isThreeWay ? "rectangle.split.3x1" : "doc.on.doc"))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(item.title).lineLimit(1)
                                Spacer()
                                Text(item.left.deletingLastPathComponent().path(percentEncoded: false))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("New Comparison")
        .onAppear(perform: openLaunchArguments)
    }

    private func pathRow(_ label: LocalizedStringKey, _ path: Binding<String>, readOnly: Binding<Bool>,
                         placeholder: LocalizedStringKey = "Type a path or drag a file here") -> some View {
        GridRow {
            Text(label)
            ComboField(text: path, prompt: Text(placeholder), choices: history.paths, acceptsDrops: true)
            Button("Browse…") { browse(path) }
            Toggle("Read Only", isOn: readOnly)
        }
    }

    private func browse(_ path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !path.wrappedValue.isEmpty { panel.directoryURL = URL(filePath: path.wrappedValue).deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url {
            path.wrappedValue = url.path(percentEncoded: false)
        }
    }

    /// Paths given on the command line open that comparison right away (for git difftool and mergetool).
    private func openLaunchArguments() {
        guard !LaunchArguments.consumed, let target = LaunchArguments.target else { return }
        LaunchArguments.consumed = true
        self.target = target
    }

    private func compare() {
        switch CompareRequest.target(left: leftPath, middle: middlePath, right: rightPath) {
        case .failure(let message):
            error = message.text
        case .success(var newTarget):
            error = nil
            newTarget.readOnlyLeft = readOnlyLeft
            newTarget.readOnlyMiddle = readOnlyMiddle
            newTarget.readOnlyRight = readOnlyRight
            newTarget.includeSubfolders = includeSubfolders
            for path in [leftPath, middlePath, rightPath] where !path.isEmpty { history.add(path) }
            target = newTarget
        }
    }
}

/// A text field with a drop-down of earlier entries, like WinMerge's path combo boxes.
private struct ComboField: View {
    @Binding var text: String
    var prompt: Text
    var choices: [String]
    var acceptsDrops = false
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 4) {
            TextField(text: $text, prompt: prompt) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: isTargeted ? 2 : 0))
                .dropDestination(for: URL.self) { urls, _ in
                    guard acceptsDrops, let url = urls.first else { return false }
                    text = url.path(percentEncoded: false)
                    return true
                } isTargeted: { isTargeted = acceptsDrops && $0 }
            Menu {
                ForEach(choices, id: \.self) { choice in
                    Button { text = choice } label: { Text(verbatim: choice) }
                }
                if choices.isEmpty { Text("No History") }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Recently used")
        }
        .frame(minWidth: 360)
    }
}

/// Paths typed or chosen in the open screen, newest first.
@MainActor
final class PathHistory: ObservableObject {
    static let shared = PathHistory()
    private static let key = "open.pathHistory"
    @Published private(set) var paths: [String] = UserDefaults.standard.stringArray(forKey: PathHistory.key) ?? []

    func add(_ path: String) {
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > 20 { paths.removeLast(paths.count - 20) }
        UserDefaults.standard.set(paths, forKey: Self.key)
    }
}

/// Ready-made file masks for the filter field.
enum FilterPresets {
    static let all = [
        "*.*",
        "!.git/;!.svn/;!node_modules/;!build/;!.build/;!DerivedData/",
        "*.swift;*.h;*.m;*.mm;*.c;*.cpp",
        "*.js;*.ts;*.jsx;*.tsx;*.json;*.css;*.html",
        "*.py;*.rb;*.go;*.rs;*.java;*.kt",
        "*.txt;*.md;*.csv",
    ]
}

/// Checks the paths typed in the open window and turns them into a comparison.
enum CompareRequest {
    struct Problem: Error, Equatable { let text: String }

    static func target(left: String, middle: String = "", right: String) -> Result<CompareTarget, Problem> {
        func expand(_ path: String) -> String { (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }
        let l = URL(filePath: expand(left)), r = URL(filePath: expand(right))
        var lDir: ObjCBool = false, rDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: l.path, isDirectory: &lDir) else { return .failure(Problem(text: L("The left path was not found"))) }
        guard FileManager.default.fileExists(atPath: r.path, isDirectory: &rDir) else { return .failure(Problem(text: L("The right path was not found"))) }
        guard lDir.boolValue == rDir.boolValue else { return .failure(Problem(text: L("A file cannot be compared with a folder"))) }
        var middleURL: URL?
        if !middle.trimmingCharacters(in: .whitespaces).isEmpty {
            var mDir: ObjCBool = false
            let m = URL(filePath: expand(middle))
            guard FileManager.default.fileExists(atPath: m.path, isDirectory: &mDir) else { return .failure(Problem(text: L("The middle path was not found"))) }
            guard !mDir.boolValue, !lDir.boolValue else { return .failure(Problem(text: L("3-way comparison works only with files"))) }
            middleURL = m
        }
        return .success(CompareTarget(left: l, right: r, middle: middleURL, kind: lDir.boolValue ? .folders : .files))
    }
}
