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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("比較するファイルまたはフォルダを選んでください")
                .font(.headline)
            PathField(label: "左", path: $leftPath)
            if showsMiddle {
                PathField(label: "中", path: $middlePath, placeholder: "ベース（共通の元ファイル）のパス")
            }
            PathField(label: "右", path: $rightPath)
            Toggle("3者比較（中央にベースを置く）", isOn: $showsMiddle)
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
                    Label("左右を入れ替え", systemImage: "arrow.left.arrow.right")
                }
                Spacer()
                Button("比較") { compare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(leftPath.isEmpty || rightPath.isEmpty)
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
        let l = URL(filePath: expand(leftPath)), r = URL(filePath: expand(rightPath))
        var lDir: ObjCBool = false, rDir: ObjCBool = false
        let lExists = FileManager.default.fileExists(atPath: l.path, isDirectory: &lDir)
        let rExists = FileManager.default.fileExists(atPath: r.path, isDirectory: &rDir)
        guard lExists else { error = "左のパスが見つかりません"; return }
        guard rExists else { error = "右のパスが見つかりません"; return }
        guard lDir.boolValue == rDir.boolValue else { error = "ファイルとフォルダは比較できません"; return }
        var middle: URL?
        if showsMiddle, !middlePath.isEmpty {
            var mDir: ObjCBool = false
            let m = URL(filePath: expand(middlePath))
            guard FileManager.default.fileExists(atPath: m.path, isDirectory: &mDir) else { error = "中央のパスが見つかりません"; return }
            guard !mDir.boolValue, !lDir.boolValue else { error = "3者比較はファイル同士だけです"; return }
            middle = m
        }
        error = nil
        openWindow(value: CompareTarget(left: l, right: r, middle: middle, kind: lDir.boolValue ? .folders : .files))
        if closesAfterCompare { dismiss() }
    }

    private func expand(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }
}

private struct PathField: View {
    let label: String
    @Binding var path: String
    var placeholder = "パスを入力するか、ここにドラッグ"
    @State private var isTargeted = false

    var body: some View {
        HStack {
            Text(label).frame(width: 20, alignment: .leading)
            TextField(placeholder, text: $path)
                .textFieldStyle(.roundedBorder)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: isTargeted ? 2 : 0))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    path = url.path(percentEncoded: false)
                    return true
                } isTargeted: { isTargeted = $0 }
            Button("参照…") { browse() }
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
