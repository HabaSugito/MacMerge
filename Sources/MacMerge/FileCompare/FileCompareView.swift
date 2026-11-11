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
                        .frame(width: controller.isThreeWay ? 48 : 34)
                    Divider()
                    HSplitView {
                        ForEach(0..<controller.paneCount, id: \.self) { paneColumn($0) }
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

    private func paneColumn(_ index: Int) -> some View {
        VStack(spacing: 0) {
            PathHeader(info: controller.info[index], role: role(index))
            Divider()
            PaneView(pane: controller.pane(index), controller: controller)
        }
        .frame(minWidth: 180)
    }

    private func role(_ index: Int) -> String? {
        guard controller.isThreeWay else { return nil }
        switch index {
        case 0: return "左"
        case 1: return controller.target.kind == .conflict ? "結果" : "ベース"
        default: return "右"
        }
    }

    private var binaryNotice: some View {
        ContentUnavailableView {
            Label("バイナリファイル", systemImage: "doc.zipper")
        } description: {
            Text(controller.binaryFilesIdentical ? "ファイルは同一です。" : "ファイルは異なります。テキストとしては比較できません。")
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
        if controller.isThreeWay {
            ToolbarItemGroup {
                Button { controller.copyRightward() } label: { Label("左から取り込む", systemImage: "arrow.right.square") }
                    .help("左の変更を中央へ取り込む (⌥→)")
                    .disabled(controller.currentHunk == nil)
                Button { controller.copyLeftward() } label: { Label("右から取り込む", systemImage: "arrow.left.square") }
                    .help("右の変更を中央へ取り込む (⌥←)")
                    .disabled(controller.currentHunk == nil)
                Button { controller.autoMerge() } label: { Label("自動マージ", systemImage: "wand.and.stars") }
                    .help("片側だけの変更をすべて中央へ取り込む (⌃⌥M)")
            }
        } else {
            ToolbarItemGroup {
                Button { controller.copyLeftward() } label: { Label("左へコピー", systemImage: "arrow.left.square") }
                    .help("右の差分を左へコピー (⌥←)")
                    .disabled(controller.currentHunk == nil)
                Button { controller.copyRightward() } label: { Label("右へコピー", systemImage: "arrow.right.square") }
                    .help("左の差分を右へコピー (⌥→)")
                    .disabled(controller.currentHunk == nil)
            }
        }
        ToolbarItem {
            CompareOptionsMenu()
        }
        ToolbarItem {
            Menu {
                Button("HTML レポートを作成…") { Exporter.saveReport(controller.makeReport()) }
                if !controller.isThreeWay {
                    Button("パッチを作成…") { Exporter.savePatch(controller.makePatch()) }
                }
            } label: {
                Label("書き出し", systemImage: "square.and.arrow.up")
            }
            .help("レポートやパッチを書き出す")
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
    var role: String?

    var body: some View {
        HStack(spacing: 4) {
            if let role {
                Text(role).fontWeight(.semibold).foregroundStyle(.secondary)
            }
            if info.isDirty {
                Circle().fill(.orange).frame(width: 7, height: 7).help("保存していない変更があります")
            }
            Text(info.title)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            if !info.file.exists, info.url != nil {
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
                let count = controller.paneCount
                let width: CGFloat = 11
                for (i, hunk) in controller.hunks.enumerated() {
                    let y = CGFloat(hunk.rows.lowerBound) * scale
                    let h = max(CGFloat(hunk.rows.count) * scale, 2)
                    let current = i == controller.currentHunk
                    let mergeable = hunk.kind != .change && hunk.kind != .conflict
                    for pane in 0..<count {
                        let isEmpty = hunk.range(pane: pane, of: count).isEmpty
                        let color: NSColor
                        if isEmpty { color = current ? DiffColors.selectedGhost : DiffColors.ghost }
                        else if mergeable { color = current ? DiffColors.selectedMergeable : DiffColors.mergeable }
                        else { color = current ? DiffColors.selected : DiffColors.changed }
                        let x = 4 + CGFloat(pane) * (width + 4)
                        ctx.fill(Path(CGRect(x: x, y: y, width: width, height: h)), with: .color(Color(nsColor: color)))
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
            if let message = controller.statusMessage {
                Text(message).lineLimit(1)
            }
            Spacer()
            ForEach(0..<controller.paneCount, id: \.self) { p in
                fileInfo(controller.info[p], label: labels[p])
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var labels: [String] { controller.isThreeWay ? ["左", "中", "右"] : ["左", "右"] }

    private var summary: String {
        let count = controller.hunks.count
        if count == 0 { return controller.isBinary ? "" : "差分はありません" }
        let conflicts = controller.isThreeWay ? "（コンフリクト \(controller.conflictCount)）" : ""
        if let c = controller.currentHunk { return "差分 \(c + 1) / \(count)" + conflicts }
        return "差分 \(count) 個" + conflicts
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
