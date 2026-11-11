import AppKit
import SwiftUI

/// The "select files or folders" window, like WinMerge's Open dialog.
struct OpenView: View {
    var closesAfterCompare = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastLeftPath") private var leftPath = ""
    @AppStorage("lastRightPath") private var rightPath = ""
    @AppStorage("lastMiddlePath") private var middlePath = ""
    @AppStorage("showMiddlePath") private var showsMiddle = false
    @State private var error: String?
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var recent = RecentComparisons.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the files or folders to compare")
                .font(.headline)
            PathField(label: "Left", path: $leftPath)
            if showsMiddle {
                PathField(label: "Middle", path: $middlePath, placeholder: "Path of the base (common ancestor) file")
            }
            PathField(label: "Right", path: $rightPath)
            Toggle("3-way comparison (base file in the middle)", isOn: $showsMiddle)
                .font(.callout)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Button {
                    swap(&leftPath, &rightPath)
                } label: {
                    Label("Swap Left and Right", systemImage: "arrow.left.arrow.right")
                }
                Spacer()
                Button("Compare") { compare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(leftPath.isEmpty || rightPath.isEmpty)
            }
            if !recent.items.isEmpty {
                Divider()
                Text("Recent Comparisons").font(.headline)
                VStack(alignment: .leading, spacing: 2) {
                        ForEach(recent.items.prefix(8), id: \.self) { target in
                            Button {
                                openWindow(value: target)
                                if closesAfterCompare { dismiss() }
                            } label: {
                                HStack {
                                    Image(systemName: target.isFolder ? "folder" : (target.isThreeWay ? "square.split.3x1" : "doc.on.doc"))
                                        .foregroundStyle(.secondary)
                                    Text(target.title).lineLimit(1)
                                    Spacer()
                                    Text(target.left.deletingLastPathComponent().path(percentEncoded: false))
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
        .padding(20)
        .frame(minWidth: 560)
        .onAppear(perform: openLaunchArguments)
    }

    /// Paths given on the command line open that comparison right away (for git difftool and mergetool).
    private func openLaunchArguments() {
        guard !LaunchArguments.consumed, let target = LaunchArguments.target else { return }
        LaunchArguments.consumed = true
        openWindow(value: target)
        if closesAfterCompare { dismiss() }
    }


    private func compare() {
        switch CompareRequest.target(left: leftPath, middle: showsMiddle ? middlePath : "", right: rightPath) {
        case .failure(let message):
            error = message.text
        case .success(let target):
            error = nil
            openWindow(value: target)
            if closesAfterCompare { dismiss() }
        }
    }

    private func expand(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }
}

private struct PathField: View {
    let label: LocalizedStringKey
    @Binding var path: String
    var placeholder = "Type a path or drag a file here"
    @State private var isTargeted = false

    var body: some View {
        HStack {
            Text(label).frame(width: 52, alignment: .leading)
            TextField(placeholder, text: $path)
                .textFieldStyle(.roundedBorder)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: isTargeted ? 2 : 0))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    path = url.path(percentEncoded: false)
                    return true
                } isTargeted: { isTargeted = $0 }
            Button("Browse…") { browse() }
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !path.isEmpty { panel.directoryURL = URL(filePath: path).deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path(percentEncoded: false)
        }
    }
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
