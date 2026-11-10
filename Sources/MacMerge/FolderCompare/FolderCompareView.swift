import AppKit
import DiffCore
import SwiftUI

@MainActor
final class FolderCompareModel: ObservableObject {
    let target: CompareTarget
    @Published private(set) var items: [FolderItem] = []
    @Published private(set) var isComparing = false
    @Published private(set) var progress = 0
    @Published var showIdentical = true { didSet { refilter() } }
    @Published var showDifferent = true { didSet { refilter() } }
    @Published var showLeftOnly = true { didSet { refilter() } }
    @Published var showRightOnly = true { didSet { refilter() } }
    @Published private(set) var visibleItems: [FolderItem] = []

    private var cancelFlag: CancelFlag?

    init(target: CompareTarget) {
        self.target = target
        compare()
    }

    func compare() {
        cancelFlag?.isCancelled = true
        let flag = CancelFlag()
        cancelFlag = flag
        isComparing = true
        progress = 0
        let left = target.left, right = target.right
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [FolderItem] in
                FolderComparer().compare(left: left, right: right, progress: { count in
                    if count % 25 == 0 {
                        Task { @MainActor [weak self] in self?.progress = count }
                    }
                }, isCancelled: { flag.isCancelled })
            }.value
            guard !flag.isCancelled else { return }
            items = result
            isComparing = false
            refilter()
        }
    }

    private func refilter() {
        visibleItems = filter(items)
    }

    private func isShown(_ item: FolderItem) -> Bool {
        switch item.result {
        case .identical, .binaryIdentical: return showIdentical
        case .leftOnly: return showLeftOnly
        case .rightOnly: return showRightOnly
        default: return showDifferent
        }
    }

    private func filter(_ list: [FolderItem]) -> [FolderItem] {
        list.compactMap { item in
            guard var children = item.children else { return isShown(item) ? item : nil }
            children = filter(children)
            if children.isEmpty && !isShown(item) { return nil }
            var copy = item
            copy.children = children.isEmpty ? nil : children
            return copy
        }
    }

    func find(_ id: String) -> FolderItem? {
        func search(_ list: [FolderItem]) -> FolderItem? {
            for item in list {
                if item.id == id { return item }
                if let found = item.children.flatMap(search) { return found }
            }
            return nil
        }
        return search(items)
    }

    func relativePath(_ item: FolderItem) -> String {
        item.id.replacingOccurrences(of: "\u{0}r", with: "")
    }

    var counts: (identical: Int, different: Int, leftOnly: Int, rightOnly: Int) {
        var c = (0, 0, 0, 0)
        func walk(_ list: [FolderItem]) {
            for item in list {
                if let children = item.children, item.left != nil, item.right != nil {
                    walk(children)
                    continue
                }
                switch item.result {
                case .identical, .binaryIdentical: c.0 += 1
                case .leftOnly: c.2 += 1
                case .rightOnly: c.3 += 1
                default: c.1 += 1
                }
            }
        }
        walk(items)
        return c
    }
}

struct FolderCompareView: View {
    @StateObject private var model: FolderCompareModel
    @State private var selection = Set<FolderItem.ID>()
    @Environment(\.openWindow) private var openWindow

    init(target: CompareTarget) {
        _model = StateObject(wrappedValue: FolderCompareModel(target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                pathLabel("左", model.target.left)
                Divider()
                pathLabel("右", model.target.right)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            table
            Divider()
            statusBar
        }
        .navigationTitle(model.target.title)
        .toolbar { toolbar }
    }

    private var table: some View {
        Table(model.visibleItems, children: \.children, selection: $selection) {
            TableColumn("名前") { item in
                Label {
                    Text(item.name)
                } icon: {
                    Image(systemName: item.isDirectory ? "folder" : "doc")
                        .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("比較結果") { item in
                ResultLabel(result: item.result)
            }
            .width(min: 110, ideal: 170)
            TableColumn("左の更新日時") { item in Text(date(item.left)) }
                .width(min: 90, ideal: 140)
            TableColumn("右の更新日時") { item in Text(date(item.right)) }
                .width(min: 90, ideal: 140)
            TableColumn("左のサイズ") { item in Text(size(item.left, item.isDirectory)).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("右のサイズ") { item in Text(size(item.right, item.isDirectory)).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("拡張子") { item in Text(item.fileExtension) }
                .width(min: 40, ideal: 60)
        }
        .contextMenu(forSelectionType: FolderItem.ID.self) { ids in
            Button("比較") { open(ids) }
                .disabled(ids.isEmpty)
            Divider()
            Button("左を Finder で表示") { reveal(ids, left: true) }
            Button("右を Finder で表示") { reveal(ids, left: false) }
        } primaryAction: { ids in
            open(ids)
        }
        .overlay {
            if model.isComparing {
                ProgressView("比較中… \(model.progress) ファイル")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if model.items.isEmpty {
                ContentUnavailableView("ファイルがありません", systemImage: "folder")
            }
        }
    }

    private func pathLabel(_ label: String, _ url: URL) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text(url.path(percentEncoded: false)).lineLimit(1).truncationMode(.head).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var statusBar: some View {
        let c = model.counts
        return HStack(spacing: 16) {
            Text("同一 \(c.identical)")
            Text("異なる \(c.different)")
            Text("左のみ \(c.leftOnly)")
            Text("右のみ \(c.rightOnly)")
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: $model.showIdentical) { Label("同一", systemImage: "equal.circle") }
                .help("同一の項目を表示")
            Toggle(isOn: $model.showDifferent) { Label("異なる", systemImage: "exclamationmark.circle") }
                .help("異なる項目を表示")
            Toggle(isOn: $model.showLeftOnly) { Label("左のみ", systemImage: "arrow.left.circle") }
                .help("左にしかない項目を表示")
            Toggle(isOn: $model.showRightOnly) { Label("右のみ", systemImage: "arrow.right.circle") }
                .help("右にしかない項目を表示")
        }
        ToolbarItem {
            Button { model.compare() } label: { Label("再比較", systemImage: "arrow.clockwise") }
                .help("もう一度比較 (⌘R)")
                .keyboardShortcut("r")
        }
    }

    private func open(_ ids: Set<FolderItem.ID>) {
        for id in ids {
            guard let item = model.find(id) else { continue }
            let path = model.relativePath(item)
            let left = model.target.left.appending(path: path)
            let right = model.target.right.appending(path: path)
            if item.isDirectory {
                // A folder that exists on both sides opens its own folder comparison.
                if item.left != nil, item.right != nil {
                    openWindow(value: CompareTarget(left: left, right: right, isFolder: true))
                }
            } else {
                openWindow(value: CompareTarget(left: left, right: right, isFolder: false))
            }
        }
    }

    private func reveal(_ ids: Set<FolderItem.ID>, left: Bool) {
        let urls = ids.compactMap { model.find($0) }
            .filter { left ? $0.left != nil : $0.right != nil }
            .map { (left ? model.target.left : model.target.right).appending(path: model.relativePath($0)) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    private func date(_ stat: FileStat?) -> String {
        stat?.modified?.formatted(date: .numeric, time: .shortened) ?? ""
    }

    private func size(_ stat: FileStat?, _ isDirectory: Bool) -> String {
        guard let stat, !isDirectory else { return "" }
        return ByteCountFormatter.string(fromByteCount: stat.size, countStyle: .file)
    }
}

private struct ResultLabel: View {
    let result: CompareResult

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(color) }
    }

    private var text: String {
        switch result {
        case .identical: return "同一"
        case .different(let count?): return "異なる（\(count) 箇所）"
        case .different: return "異なる"
        case .leftOnly: return "左のみ"
        case .rightOnly: return "右のみ"
        case .binaryIdentical: return "バイナリ：同一"
        case .binaryDifferent: return "バイナリ：異なる"
        case .error(let message): return "エラー：\(message)"
        }
    }

    private var icon: String {
        switch result {
        case .identical, .binaryIdentical: return "equal.circle.fill"
        case .different, .binaryDifferent: return "exclamationmark.circle.fill"
        case .leftOnly: return "arrow.left.circle.fill"
        case .rightOnly: return "arrow.right.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch result {
        case .identical, .binaryIdentical: return .green
        case .different, .binaryDifferent: return .orange
        case .leftOnly, .rightOnly: return .gray
        case .error: return .red
        }
    }
}

/// Lets a newer comparison stop an older one that is still running.
private final class CancelFlag: @unchecked Sendable {
    var isCancelled = false
}
