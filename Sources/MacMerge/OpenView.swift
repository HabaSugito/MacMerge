import AppKit
import SwiftUI

/// The "select files or folders" window, like WinMerge's Open dialog.
struct OpenView: View {
    var closesAfterCompare = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastLeftPath") private var leftPath = ""
    @AppStorage("lastRightPath") private var rightPath = ""
    @State private var error: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("比較するファイルまたはフォルダを選んでください")
                .font(.headline)
            PathField(label: "左", path: $leftPath)
            PathField(label: "右", path: $rightPath)
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

    /// `MacMerge <left> <right>` opens that comparison right away (for git difftool and scripts).
    private func openLaunchArguments() {
        let args = LaunchArguments.paths
        guard args.count == 2, !LaunchArguments.consumed else { return }
        LaunchArguments.consumed = true
        leftPath = args[0]
        rightPath = args[1]
        compare()
    }


    private func compare() {
        let l = URL(filePath: expand(leftPath)), r = URL(filePath: expand(rightPath))
        var lDir: ObjCBool = false, rDir: ObjCBool = false
        let lExists = FileManager.default.fileExists(atPath: l.path, isDirectory: &lDir)
        let rExists = FileManager.default.fileExists(atPath: r.path, isDirectory: &rDir)
        guard lExists else { error = "左のパスが見つかりません"; return }
        guard rExists else { error = "右のパスが見つかりません"; return }
        guard lDir.boolValue == rDir.boolValue else { error = "ファイルとフォルダは比較できません"; return }
        error = nil
        openWindow(value: CompareTarget(left: l, right: r, isFolder: lDir.boolValue))
        if closesAfterCompare { dismiss() }
    }

    private func expand(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }
}

private struct PathField: View {
    let label: String
    @Binding var path: String
    @State private var isTargeted = false

    var body: some View {
        HStack {
            Text(label).frame(width: 20, alignment: .leading)
            TextField("パスを入力するか、ここにドラッグ", text: $path)
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
