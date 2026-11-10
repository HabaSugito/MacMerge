import AppKit
import DiffCore
import SwiftUI

struct FileCompareView: View {
    @StateObject private var controller: FileCompareController

    init(target: CompareTarget) {
        _controller = StateObject(wrappedValue: FileCompareController(target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = controller.loadError {
                ContentUnavailableView("ファイルを開けませんでした", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if controller.isBinary {
                binaryNotice
            } else {
                HStack(spacing: 0) {
                    LocationPane(controller: controller)
                        .frame(width: 34)
                    Divider()
                    HSplitView {
                        paneColumn(.left)
                        paneColumn(.right)
                    }
                }
            }
            Divider()
            StatusBar(controller: controller)
        }
        .navigationTitle(controller.target.title)
        .toolbar { toolbar }
        .focusedSceneValue(\.fileCompare, controller)
    }

    private func paneColumn(_ side: Side) -> some View {
        VStack(spacing: 0) {
            PathHeader(info: controller.info[side.rawValue])
            Divider()
            PaneView(pane: controller.pane(side), controller: controller)
        }
        .frame(minWidth: 200)
    }

    private var binaryNotice: some View {
        ContentUnavailableView {
            Label("バイナリファイル", systemImage: "doc.zipper")
        } description: {
            Text(controller.binaryFilesIdentical ? "2つのファイルは同一です。" : "2つのファイルは異なります。テキストとしては比較できません。")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { controller.previousDifference() } label: { Label("前の差分", systemImage: "chevron.up") }
                .help("前の差分 (⌥↑)")
            Button { controller.nextDifference() } label: { Label("次の差分", systemImage: "chevron.down") }
                .help("次の差分 (⌥↓)")
        }
        ToolbarItemGroup {
            Button { controller.copyCurrent(from: .right) } label: { Label("左へコピー", systemImage: "arrow.left.square") }
                .help("右の差分を左へコピー (⌥←)")
                .disabled(controller.currentHunk == nil)
            Button { controller.copyCurrent(from: .left) } label: { Label("右へコピー", systemImage: "arrow.right.square") }
                .help("左の差分を右へコピー (⌥→)")
                .disabled(controller.currentHunk == nil)
        }
        ToolbarItemGroup {
            Button { controller.saveAll() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                .help("保存 (⌘S)")
                .disabled(!controller.isDirty)
            Button { controller.reload() } label: { Label("再読み込み", systemImage: "arrow.clockwise") }
                .help("ファイルを読み直して再比較 (⌘R)")
        }
    }
}

/// Embeds one AppKit pane and tells the controller which window it lives in.
private struct PaneView: NSViewRepresentable {
    let pane: DiffPane
    let controller: FileCompareController

    func makeNSView(context: Context) -> NSScrollView { pane.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window, controller.window !== window { controller.window = window }
        }
    }
}

private struct PathHeader: View {
    let info: PaneInfo

    var body: some View {
        HStack(spacing: 4) {
            if info.isDirty {
                Circle().fill(.orange).frame(width: 7, height: 7).help("保存していない変更があります")
            }
            Text(info.url.path(percentEncoded: false))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            if !info.file.exists {
                Text("（ファイルなし）").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

/// A map of the whole comparison. Click or drag to jump.
private struct LocationPane: View {
    @ObservedObject var controller: FileCompareController

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let total = CGFloat(max(controller.rowCount, 1))
                let scale = size.height / total
                let columns = [CGRect(x: 4, y: 0, width: 11, height: 0), CGRect(x: 19, y: 0, width: 11, height: 0)]
                for (i, hunk) in controller.hunks.enumerated() {
                    let y = CGFloat(hunk.rows.lowerBound) * scale
                    let h = max(CGFloat(hunk.rows.count) * scale, 2)
                    let current = i == controller.currentHunk
                    for (side, column) in columns.enumerated() {
                        let isEmpty = side == 0 ? hunk.left.isEmpty : hunk.right.isEmpty
                        let color: NSColor = isEmpty
                            ? (current ? DiffColors.selectedGhost : DiffColors.ghost)
                            : (current ? DiffColors.selected : DiffColors.changed)
                        ctx.fill(Path(CGRect(x: column.minX, y: y, width: column.width, height: h)), with: .color(Color(nsColor: color)))
                    }
                }
                let v = controller.visibleRows
                if !v.isEmpty {
                    let rect = CGRect(x: 1, y: CGFloat(v.lowerBound) * scale, width: size.width - 2, height: max(CGFloat(v.count) * scale, 4))
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(.secondary), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                controller.scrollToFraction(value.location.y / max(geo.size.height, 1))
            })
        }
        .background(Color(nsColor: DiffColors.gutter))
        .help("差分の位置。クリックでその場所へ移動")
    }
}

private struct StatusBar: View {
    @ObservedObject var controller: FileCompareController

    var body: some View {
        HStack(spacing: 16) {
            Text(summary)
            Spacer()
            fileInfo(controller.info[0], label: "左")
            fileInfo(controller.info[1], label: "右")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var summary: String {
        let count = controller.hunks.count
        if count == 0 { return controller.isBinary ? "" : "差分はありません" }
        if let c = controller.currentHunk { return "差分 \(c + 1) / \(count)" }
        return "差分 \(count) 個"
    }

    private func fileInfo(_ info: PaneInfo, label: String) -> some View {
        Text("\(label): \(info.file.encodingName)  \(info.file.lineEnding.rawValue)")
            .monospacedDigit()
    }
}

// MARK: Focused value used by menu commands

struct FileCompareKey: FocusedValueKey {
    typealias Value = FileCompareController
}

extension FocusedValues {
    var fileCompare: FileCompareController? {
        get { self[FileCompareKey.self] }
        set { self[FileCompareKey.self] = newValue }
    }
}
