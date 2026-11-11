import AppKit
import DiffCore
import SwiftUI

@MainActor
final class FolderCompareModel: ObservableObject {
    let target: CompareTarget
    @Published private(set) var items: [FolderItem] = []
    @Published private(set) var visibleItems: [FolderItem] = []
    @Published private(set) var isComparing = false
    @Published private(set) var progress = 0
    @Published var selection = Set<FolderItem.ID>()
    @Published var sortOrder = [KeyPathComparator(\FolderItem.name)] { didSet { refilter() } }
    @Published var showIdentical = true { didSet { refilter() } }
    @Published var showDifferent = true { didSet { refilter() } }
    @Published var showLeftOnly = true { didSet { refilter() } }
    @Published var showRightOnly = true { didSet { refilter() } }
    @Published var filterText = CompareSettings.fileFilter

    private var options = CompareSettings.options
    private var cancelFlag: CancelFlag?
    private var defaultsObserver: NSObjectProtocol?

    init(target: CompareTarget) {
        self.target = target
        compare()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    private func defaultsChanged() {
        let new = CompareSettings.options
        guard new != options else { return }
        options = new
        compare()
    }

    // MARK: Comparing

    func compare() {
        cancelFlag?.isCancelled = true
        let flag = CancelFlag()
        cancelFlag = flag
        isComparing = true
        progress = 0
        let left = target.left, right = target.right
        let comparer = FolderComparer(options: options, filter: FileFilter(filterText))
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [FolderItem] in
                comparer.compare(left: left, right: right, progress: { count in
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

    /// Saves the file mask and compares again with it.
    func applyFilter() {
        UserDefaults.standard.set(filterText, forKey: CompareSettings.fileFilterKey)
        compare()
    }

    private func refilter() {
        visibleItems = sorted(filter(items))
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

    /// Sorts each level by the chosen column, keeping folders above files.
    private func sorted(_ list: [FolderItem]) -> [FolderItem] {
        let folders = list.filter(\.isDirectory).sorted(using: sortOrder)
        let files = list.filter { !$0.isDirectory }.sorted(using: sortOrder)
        return (folders + files).map { item in
            var copy = item
            copy.children = item.children.map(sorted)
            return copy
        }
    }

    // MARK: Lookup

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

    func url(_ item: FolderItem, left: Bool) -> URL {
        (left ? target.left : target.right).appending(path: relativePath(item))
    }

    private var selectedItems: [FolderItem] {
        selection.compactMap(find).sorted { $0.id < $1.id }
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

    // MARK: File operations

    /// Items that can be copied in the given direction: they exist on the source side
    /// and are not already identical.
    func copyable(toRight: Bool) -> [FolderItem] {
        let items = selectedItems.filter { (toRight ? $0.left : $0.right) != nil && $0.result.isDifferent }
        // Copying a folder copies its contents, so drop items inside another selected folder.
        return items.filter { item in
            !items.contains { other in other.isDirectory && other.id != item.id && relativePath(item).hasPrefix(relativePath(other) + "/") }
        }
    }

    func copySelected(toRight: Bool) {
        let items = copyable(toRight: toRight)
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "\(items.count) 項目を\(toRight ? "右" : "左")へコピーしますか？"
        alert.informativeText = itemList(items) + "\n\n同じ名前のファイルは上書きされます。"
        alert.addButton(withTitle: "コピー")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(items) { try FileOperations.copy(self.url($0, left: toRight), to: self.url($0, left: !toRight)) }
    }

    var canDelete: Bool { !selectedItems.isEmpty }

    func deleteSelected() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let hasLeft = items.contains { $0.left != nil }
        let hasRight = items.contains { $0.right != nil }
        let alert = NSAlert()
        alert.messageText = "\(items.count) 項目をゴミ箱に移動しますか？"
        alert.informativeText = itemList(items)
        var choices: [(left: Bool, right: Bool)] = []
        if hasLeft && hasRight { alert.addButton(withTitle: "両方"); choices.append((true, true)) }
        if hasLeft { alert.addButton(withTitle: "左のみ"); choices.append((true, false)) }
        if hasRight { alert.addButton(withTitle: "右のみ"); choices.append((false, true)) }
        alert.addButton(withTitle: "キャンセル")
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(index) else { return }
        let choice = choices[index]
        perform(items) { item in
            if choice.left, item.left != nil { try FileOperations.moveToTrash(self.url(item, left: true)) }
            if choice.right, item.right != nil { try FileOperations.moveToTrash(self.url(item, left: false)) }
        }
    }

    private func perform(_ items: [FolderItem], _ operation: (FolderItem) throws -> Void) {
        var errors: [String] = []
        for item in items {
            do { try operation(item) } catch { errors.append("\(relativePath(item)): \(error.localizedDescription)") }
        }
        if !errors.isEmpty {
            let alert = NSAlert()
            alert.messageText = "一部の項目を処理できませんでした"
            alert.informativeText = errors.prefix(10).joined(separator: "\n")
            alert.runModal()
        }
        compare()
    }

    private func itemList(_ items: [FolderItem]) -> String {
        let names = items.prefix(8).map(relativePath)
        return names.joined(separator: "\n") + (items.count > 8 ? "\nほか \(items.count - 8) 項目" : "")
    }
}

/// Lets a newer comparison stop an older one that is still running.
private final class CancelFlag: @unchecked Sendable {
    var isCancelled = false
}

/// Values the table sorts by.
extension FolderItem {
    var resultSortKey: Int {
        switch result {
        case .different, .binaryDifferent: return 0
        case .leftOnly: return 1
        case .rightOnly: return 2
        case .error: return 3
        case .identical, .binaryIdentical: return 4
        }
    }
    var leftDate: Date { left?.modified ?? .distantPast }
    var rightDate: Date { right?.modified ?? .distantPast }
    var leftSize: Int64 { left?.size ?? -1 }
    var rightSize: Int64 { right?.size ?? -1 }
}

struct FolderCompareView: View {
    @StateObject private var model: FolderCompareModel
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
        .focusedSceneValue(\.folderCompare, model)
    }

    private var table: some View {
        Table(model.visibleItems, children: \.children, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("名前", value: \.name) { item in
                Label {
                    Text(item.name)
                } icon: {
                    Image(systemName: item.isDirectory ? "folder" : "doc")
                        .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("比較結果", value: \.resultSortKey) { item in
                ResultLabel(result: item.result)
            }
            .width(min: 110, ideal: 190)
            TableColumn("左の更新日時", value: \.leftDate) { item in Text(date(item.left)) }
                .width(min: 90, ideal: 140)
            TableColumn("右の更新日時", value: \.rightDate) { item in Text(date(item.right)) }
                .width(min: 90, ideal: 140)
            TableColumn("左のサイズ", value: \.leftSize) { item in Text(size(item.left, item.isDirectory)).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("右のサイズ", value: \.rightSize) { item in Text(size(item.right, item.isDirectory)).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("拡張子", value: \.fileExtension) { item in Text(item.fileExtension) }
                .width(min: 40, ideal: 60)
        }
        .contextMenu(forSelectionType: FolderItem.ID.self) { ids in
            Button("比較") { open(ids) }
                .disabled(ids.isEmpty)
            Divider()
            Button("右へコピー…") { model.selection = ids; model.copySelected(toRight: true) }
                .disabled(ids.isEmpty)
            Button("左へコピー…") { model.selection = ids; model.copySelected(toRight: false) }
                .disabled(ids.isEmpty)
            Button("ゴミ箱に入れる…") { model.selection = ids; model.deleteSelected() }
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
            if !model.filterText.isEmpty {
                Text("フィルタ: \(model.filterText)").lineLimit(1)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            TextField("フィルタ（例: *.swift;!build/）", text: $model.filterText)
                .frame(width: 220)
                .onSubmit { model.applyFilter() }
                .help("比較するファイルの条件。; で区切り、! を付けると除外。末尾が / ならフォルダ。Return で適用")
        }
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
        ToolbarItemGroup {
            Button { model.copySelected(toRight: false) } label: { Label("左へコピー", systemImage: "arrow.left.square") }
                .help("選択した項目を左へコピー (⌥←)")
                .disabled(model.copyable(toRight: false).isEmpty)
            Button { model.copySelected(toRight: true) } label: { Label("右へコピー", systemImage: "arrow.right.square") }
                .help("選択した項目を右へコピー (⌥→)")
                .disabled(model.copyable(toRight: true).isEmpty)
            Button { model.deleteSelected() } label: { Label("ゴミ箱に入れる", systemImage: "trash") }
                .help("選択した項目をゴミ箱に入れる (⌘⌫)")
                .disabled(!model.canDelete)
        }
        ToolbarItem {
            CompareOptionsMenu()
        }
        ToolbarItem {
            Button { model.compare() } label: { Label("再比較", systemImage: "arrow.clockwise") }
                .help("もう一度比較 (⌘R)")
        }
    }

    private func open(_ ids: Set<FolderItem.ID>) {
        for id in ids {
            guard let item = model.find(id) else { continue }
            let left = model.url(item, left: true)
            let right = model.url(item, left: false)
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
            .map { model.url($0, left: left) }
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
        case .different(0): return "異なる（改行・文字コードのみ）"
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

struct FolderCompareKey: FocusedValueKey {
    typealias Value = FolderCompareModel
}

extension FocusedValues {
    var folderCompare: FolderCompareModel? {
        get { self[FolderCompareKey.self] }
        set { self[FolderCompareKey.self] = newValue }
    }
}
