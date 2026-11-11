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
    /// Tree view (folders that open and close) or a flat list of every file.
    @Published var treeMode = UserDefaults.standard.object(forKey: "folder.treeMode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(treeMode, forKey: "folder.treeMode"); refilter() }
    }
    /// Compare again automatically when files in either folder change.
    @Published var watchesChanges = UserDefaults.standard.object(forKey: "folder.watchChanges") as? Bool ?? true {
        didSet { UserDefaults.standard.set(watchesChanges, forKey: "folder.watchChanges"); updateWatcher() }
    }
    private var watcher: FolderWatcher?

    private var options = CompareSettings.options
    private var cancelFlag: CancelFlag?
    private var defaultsObserver: NSObjectProtocol?

    init(target: CompareTarget) {
        self.target = target
        compare()
        updateWatcher()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    private var detectRenames = CompareSettings.detectRenames

    private func defaultsChanged() {
        let new = CompareSettings.options
        guard new != options || detectRenames != CompareSettings.detectRenames else { return }
        options = new
        detectRenames = CompareSettings.detectRenames
        compare()
    }

    private func updateWatcher() {
        watcher = watchesChanges ? FolderWatcher(paths: [target.left, target.right]) { [weak self] in
            guard let self, !self.isComparing else { return }
            self.compare()
        } : nil
    }

    // MARK: Comparing

    func compare() {
        cancelFlag?.isCancelled = true
        let flag = CancelFlag()
        cancelFlag = flag
        isComparing = true
        progress = 0
        let left = target.left, right = target.right
        let comparer = FolderComparer(options: options, filter: FileFilter(filterText), detectRenames: detectRenames)
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
        let filtered = sorted(filter(items))
        visibleItems = treeMode ? filtered : flatten(filtered).sorted(using: sortOrder)
    }

    /// Every file, plus folders that exist on one side only, without nesting.
    private func flatten(_ list: [FolderItem]) -> [FolderItem] {
        list.flatMap { item -> [FolderItem] in
            guard let children = item.children else { return [item] }
            if item.left == nil || item.right == nil {
                var folder = item
                folder.children = nil
                return [folder]
            }
            return flatten(children)
        }
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

    // MARK: Report and patch

    func makeReport() -> String {
        HTMLReport.folderComparison(left: target.left, right: target.right, items: items)
    }

    /// One patch for every differing text file, with paths relative to the compared folders.
    func makePatch() -> String {
        var patch = ""
        func walk(_ list: [FolderItem]) {
            for item in list {
                if let children = item.children { walk(children); continue }
                guard item.result.isDifferent, !item.isDirectory else { continue }
                let path = relativePath(item)
                let old = item.left != nil ? (try? TextFile.load(url(item, left: true))) : TextFile.empty
                let new = item.right != nil ? (try? TextFile.load(url(item, left: false))) : TextFile.empty
                guard let old, let new, !old.isBinary, !new.isBinary else { continue }
                patch += UnifiedDiff.make(oldName: item.left != nil ? "a/\(path)" : "/dev/null",
                                          newName: item.right != nil ? "b/\(path)" : "/dev/null",
                                          oldText: old.text, newText: new.text)
            }
        }
        walk(items)
        return patch
    }

    // MARK: Other actions

    /// Packs the selected items of one side into a Zip file, keeping their folder paths.
    func zipSelected(left: Bool) {
        let items = selectedItems.filter { left ? $0.left != nil : $0.right != nil }
        guard !items.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (left ? target.left : target.right).lastPathComponent + ".zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/zip")
        process.currentDirectoryURL = left ? target.left : target.right
        process.arguments = ["-r", "-q", dest.path] + items.map(relativePath)
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func openExternally(_ ids: Set<FolderItem.ID>, left: Bool) {
        for item in ids.compactMap(find) where (left ? item.left : item.right) != nil {
            NSWorkspace.shared.open(url(item, left: left))
        }
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
        alert.messageText = toRight ? L("Copy \(items.count) items to the right?") : L("Copy \(items.count) items to the left?")
        alert.informativeText = itemList(items) + "\n\n" + L("Files with the same name will be replaced.")
        alert.addButton(withTitle: L("Copy"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        showErrors(performCopy(items, toRight: toRight))
    }

    /// Copies items without asking. Returns a message for each item that failed.
    @discardableResult
    func performCopy(_ items: [FolderItem], toRight: Bool) -> [String] {
        perform(items) { try FileOperations.copy(self.url($0, left: toRight), to: self.url($0, left: !toRight)) }
    }

    var canDelete: Bool { !selectedItems.isEmpty }

    func deleteSelected() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let hasLeft = items.contains { $0.left != nil }
        let hasRight = items.contains { $0.right != nil }
        let alert = NSAlert()
        alert.messageText = L("Move \(items.count) items to the Trash?")
        alert.informativeText = itemList(items)
        var choices: [(left: Bool, right: Bool)] = []
        if hasLeft && hasRight { alert.addButton(withTitle: L("Both")); choices.append((true, true)) }
        if hasLeft { alert.addButton(withTitle: L("Left only")); choices.append((true, false)) }
        if hasRight { alert.addButton(withTitle: L("Right only")); choices.append((false, true)) }
        alert.addButton(withTitle: L("Cancel"))
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(index) else { return }
        let choice = choices[index]
        showErrors(performTrash(items, left: choice.left, right: choice.right))
    }

    /// Moves items to the Trash without asking. Returns a message for each item that failed.
    @discardableResult
    func performTrash(_ items: [FolderItem], left: Bool, right: Bool) -> [String] {
        perform(items) { item in
            if left, item.left != nil { try FileOperations.moveToTrash(self.url(item, left: true)) }
            if right, item.right != nil { try FileOperations.moveToTrash(self.url(item, left: false)) }
        }
    }

    private func perform(_ items: [FolderItem], _ operation: (FolderItem) throws -> Void) -> [String] {
        var errors: [String] = []
        for item in items {
            do { try operation(item) } catch { errors.append("\(relativePath(item)): \(error.localizedDescription)") }
        }
        compare()
        return errors
    }

    private func showErrors(_ errors: [String]) {
        guard !errors.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("Some items could not be processed")
        alert.informativeText = errors.prefix(10).joined(separator: "\n")
        alert.runModal()
    }

    private func itemList(_ items: [FolderItem]) -> String {
        let names = items.prefix(8).map(relativePath)
        return names.joined(separator: "\n") + (items.count > 8 ? "\n" + L("and \(items.count - 8) more") : "")
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
        case .moved: return 1
        case .identical, .binaryIdentical: return 4
        }
    }
    var folderPath: String { (id.replacingOccurrences(of: "\u{0}r", with: "") as NSString).deletingLastPathComponent }
    var leftDate: Date { left?.modified ?? .distantPast }
    var rightDate: Date { right?.modified ?? .distantPast }
    var leftSize: Int64 { left?.size ?? -1 }
    var rightSize: Int64 { right?.size ?? -1 }
}

struct FolderCompareView: View {
    @StateObject private var model: FolderCompareModel
    @Environment(\.openWindow) private var openWindow
    @State private var columns = FolderColumns.load()

    init(target: CompareTarget) {
        _model = StateObject(wrappedValue: FolderCompareModel(target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                pathLabel("Left", model.target.left)
                Divider()
                pathLabel("Right", model.target.right)
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
        .onAppear { RecentComparisons.shared.add(model.target) }
    }

    private var table: some View {
        Table(model.visibleItems, children: \.children, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \.name) { item in
                Label {
                    Text(item.name)
                } icon: {
                    Image(systemName: item.isDirectory ? "folder" : "doc")
                        .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                }
            }
            .width(min: 160, ideal: 260)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Folder", value: \.folderPath) { item in Text(item.folderPath).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 180)
                .customizationID("folder")
                .defaultVisibility(.hidden)
            TableColumn("Result", value: \.resultSortKey) { item in
                ResultLabel(result: item.result)
            }
            .width(min: 110, ideal: 190)
            .customizationID("result")
            TableColumn("Left Modified", value: \.leftDate) { item in Text(date(item.left)) }
                .width(min: 90, ideal: 140)
                .customizationID("leftDate")
            TableColumn("Right Modified", value: \.rightDate) { item in Text(date(item.right)) }
                .width(min: 90, ideal: 140)
                .customizationID("rightDate")
            TableColumn("Left Size", value: \.leftSize) { item in Text(size(item.left, item.isDirectory)).monospacedDigit() }
                .width(min: 60, ideal: 80)
                .customizationID("leftSize")
            TableColumn("Right Size", value: \.rightSize) { item in Text(size(item.right, item.isDirectory)).monospacedDigit() }
                .width(min: 60, ideal: 80)
                .customizationID("rightSize")
            TableColumn("Extension", value: \.fileExtension) { item in Text(item.fileExtension) }
                .width(min: 40, ideal: 60)
                .customizationID("extension")
        }
        .onChange(of: columns) { _, new in FolderColumns.save(new) }
        .onChange(of: model.treeMode) { _, tree in
            // The folder column is what tells files apart in the flat list.
            columns[visibility: "folder"] = tree ? .hidden : .visible
        }
        .contextMenu(forSelectionType: FolderItem.ID.self) { ids in
            Button("Compare") { open(ids) }
                .disabled(ids.isEmpty)
            Divider()
            Button("Copy to Right…") { model.selection = ids; model.copySelected(toRight: true) }
                .disabled(ids.isEmpty)
            Button("Copy to Left…") { model.selection = ids; model.copySelected(toRight: false) }
                .disabled(ids.isEmpty)
            Button("Move to Trash…") { model.selection = ids; model.deleteSelected() }
                .disabled(ids.isEmpty)
            Divider()
            Button("Show Left in Finder") { reveal(ids, left: true) }
            Button("Show Right in Finder") { reveal(ids, left: false) }
            Button("Open Left in Default App") { model.openExternally(ids, left: true) }
            Button("Open Right in Default App") { model.openExternally(ids, left: false) }
            Divider()
            Button("Zip Left Items…") { model.selection = ids; model.zipSelected(left: true) }
            Button("Zip Right Items…") { model.selection = ids; model.zipSelected(left: false) }
        } primaryAction: { ids in
            open(ids)
        }
        .overlay {
            if model.isComparing {
                ProgressView("Comparing… \(model.progress) files")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if model.items.isEmpty {
                ContentUnavailableView("No Files", systemImage: "folder")
            }
        }
    }

    private func pathLabel(_ label: LocalizedStringKey, _ url: URL) -> some View {
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
            Text("Identical \(c.identical)")
            Text("Different \(c.different)")
            Text("Left only \(c.leftOnly)")
            Text("Right only \(c.rightOnly)")
            Spacer()
            if !model.filterText.isEmpty {
                Text("Filter: \(model.filterText)").lineLimit(1)
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
            TextField("Filter (e.g. *.swift;!build/)", text: $model.filterText)
                .frame(width: 220)
                .onSubmit { model.applyFilter() }
                .help("Which files to compare. Separate patterns with ;, put ! in front to exclude, and end a pattern with / for folders. Press Return to apply.")
        }
        ToolbarItemGroup {
            Toggle(isOn: $model.showIdentical) { Label("Identical", systemImage: "equal.circle") }
                .help("Show identical items")
            Toggle(isOn: $model.showDifferent) { Label("Different", systemImage: "exclamationmark.circle") }
                .help("Show different items")
            Toggle(isOn: $model.showLeftOnly) { Label("Left only", systemImage: "arrow.left.circle") }
                .help("Show items only on the left")
            Toggle(isOn: $model.showRightOnly) { Label("Right only", systemImage: "arrow.right.circle") }
                .help("Show items only on the right")
        }
        ToolbarItemGroup {
            Button { model.copySelected(toRight: false) } label: { Label("Copy to Left", systemImage: "arrow.left.square") }
                .help("Copy the selected items to the left (⌥←)")
                .disabled(model.copyable(toRight: false).isEmpty)
            Button { model.copySelected(toRight: true) } label: { Label("Copy to Right", systemImage: "arrow.right.square") }
                .help("Copy the selected items to the right (⌥→)")
                .disabled(model.copyable(toRight: true).isEmpty)
            Button { model.deleteSelected() } label: { Label("Move to Trash", systemImage: "trash") }
                .help("Move the selected items to the Trash (⌘⌫)")
                .disabled(!model.canDelete)
        }
        ToolbarItem {
            Toggle(isOn: $model.treeMode) { Label("Tree View", systemImage: "list.bullet.indent") }
                .help("Show folders as a tree, or every file in one flat list")
        }
        ToolbarItem {
            Menu {
                CompareOptionControls()
                Divider()
                FolderOptionControls()
                Toggle("Watch for Changes", isOn: $model.watchesChanges)
            } label: {
                Label("Compare Options", systemImage: "slider.horizontal.3")
            }
            .help("Compare Options")
        }
        ToolbarItem {
            Button { model.compare() } label: { Label("Compare Again", systemImage: "arrow.clockwise") }
                .help("Compare again (⌘R)")
        }
    }

    private func open(_ ids: Set<FolderItem.ID>) {
        for id in ids {
            guard let item = model.find(id) else { continue }
            let left = model.url(item, left: true)
            let right = model.url(item, left: false)
            if case .moved(let other) = item.result {
                // Compare a renamed or moved file with its counterpart.
                let otherURL = (item.left != nil ? model.target.right : model.target.left).appending(path: other)
                openWindow(value: item.left != nil
                    ? CompareTarget(left: left, right: otherURL, isFolder: false)
                    : CompareTarget(left: otherURL, right: right, isFolder: false))
                continue
            }
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
        case .identical: return L("Identical")
        case .different(0): return L("Different (line endings or encoding only)")
        case .different(let count?): return L("Different (\(count))")
        case .different: return L("Different")
        case .leftOnly: return L("Left only")
        case .rightOnly: return L("Right only")
        case .binaryIdentical: return L("Binary: identical")
        case .binaryDifferent: return L("Binary: different")
        case .error(let message): return L("Error: \(message)")
        case .moved(let other): return L("Renamed or moved: \(other)")
        }
    }

    private var icon: String {
        switch result {
        case .identical, .binaryIdentical: return "equal.circle.fill"
        case .different, .binaryDifferent: return "exclamationmark.circle.fill"
        case .leftOnly: return "arrow.left.circle.fill"
        case .rightOnly: return "arrow.right.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .moved: return "arrow.triangle.swap"
        }
    }

    private var color: Color {
        switch result {
        case .identical, .binaryIdentical: return .green
        case .different, .binaryDifferent: return .orange
        case .leftOnly, .rightOnly: return .gray
        case .moved: return .blue
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

/// Which folder-compare columns are shown, in what order and width; kept between launches.
enum FolderColumns {
    private static let key = "folder.columns"

    static func load() -> TableColumnCustomization<FolderItem> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(TableColumnCustomization<FolderItem>.self, from: data) else { return .init() }
        return value
    }

    static func save(_ value: TableColumnCustomization<FolderItem>) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
