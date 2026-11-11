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
                ContentUnavailableView("The Files Could Not Be Opened", systemImage: "exclamationmark.triangle", description: Text(error))
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
        .onAppear { RecentComparisons.shared.add(controller.target) }
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
        case 0: return L("Left")
        case 1: return controller.target.kind == .conflict ? L("Merge Result") : L("Base")
        default: return L("Right")
        }
    }

    private var binaryNotice: some View {
        ContentUnavailableView {
            Label("Binary Files", systemImage: "doc.zipper")
        } description: {
            Text(controller.binaryFilesIdentical ? "The files are identical." : "The files are different. They cannot be compared as text.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { controller.previousDifference() } label: { Label("Previous Difference", systemImage: "chevron.up") }
                .help("Previous difference (⌥↑)")
            Button { controller.nextDifference() } label: { Label("Next Difference", systemImage: "chevron.down") }
                .help("Next difference (⌥↓)")
        }
        if controller.isThreeWay {
            ToolbarItemGroup {
                Button { controller.copyRightward() } label: { Label("Take Left", systemImage: "arrow.right.square") }
                    .help("Take the left change into the middle (⌥→)")
                    .disabled(controller.currentHunk == nil)
                Button { controller.copyLeftward() } label: { Label("Take Right", systemImage: "arrow.left.square") }
                    .help("Take the right change into the middle (⌥←)")
                    .disabled(controller.currentHunk == nil)
                Button { controller.autoMerge() } label: { Label("Auto Merge", systemImage: "wand.and.stars") }
                    .help("Take every one-sided change into the middle (⌃⌥M)")
            }
        } else {
            ToolbarItemGroup {
                Button { controller.copyLeftward() } label: { Label("Copy to Left", systemImage: "arrow.left.square") }
                    .help("Copy the right difference to the left (⌥←)")
                    .disabled(controller.currentHunk == nil)
                Button { controller.copyRightward() } label: { Label("Copy to Right", systemImage: "arrow.right.square") }
                    .help("Copy the left difference to the right (⌥→)")
                    .disabled(controller.currentHunk == nil)
            }
        }
        ToolbarItem {
            CompareOptionsMenu()
        }
        ToolbarItem {
            Menu {
                Button("Create HTML Report…") { Exporter.saveReport(controller.makeReport()) }
                if !controller.isThreeWay {
                    Button("Create Patch…") { Exporter.savePatch(controller.makePatch()) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export a report or a patch")
        }
        ToolbarItemGroup {
            Button { controller.saveAll() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .help("Save (⌘S)")
                .disabled(!controller.isDirty)
            Button { controller.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .help("Reload the files and compare again (⌘R)")
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
                Circle().fill(.orange).frame(width: 7, height: 7).help("There are unsaved changes")
            }
            if info.isReadOnly {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Read Only")
            }
            Text(info.title)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            if !info.file.exists, info.url != nil {
                Text("(no file)").foregroundStyle(.secondary)
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
        .help("Where the differences are. Click to go there.")
    }
}

private struct StatusBar: View {
    @ObservedObject var controller: FileCompareController

    var body: some View {
        HStack(spacing: 16) {
            Text(summary)
            if controller.mergeMode {
                Text("Merge Mode").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                    .help("Arrow keys move between differences (↑↓) and copy them (←→). Press F9 to turn off.")
            }
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

    private var labels: [String] { controller.isThreeWay ? [L("Left"), L("Middle"), L("Right")] : [L("Left"), L("Right")] }

    private var summary: String {
        let count = controller.hunks.count
        if count == 0 { return controller.isBinary ? "" : L("No differences") }
        let conflicts = controller.isThreeWay ? L(" (\(controller.conflictCount) conflicts)") : ""
        if let c = controller.currentHunk { return L("Difference \(c + 1) of \(count)") + conflicts }
        return L("\(count) differences") + conflicts
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
