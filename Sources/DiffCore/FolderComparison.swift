import Foundation

public enum CompareResult: Equatable {
    case identical
    case different(diffCount: Int?)
    case leftOnly
    case rightOnly
    case binaryIdentical
    case binaryDifferent
    case error(String)

    public var isDifferent: Bool {
        switch self {
        case .identical, .binaryIdentical: return false
        default: return true
        }
    }
}

public struct FileStat: Equatable {
    public var size: Int64
    public var modified: Date?
}

/// One file or folder in a folder comparison. `id` is the path relative to the compared roots.
public struct FolderItem: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var isDirectory: Bool
    public var left: FileStat?
    public var right: FileStat?
    public var result: CompareResult
    public var children: [FolderItem]?

    public var fileExtension: String {
        isDirectory ? "" : (name as NSString).pathExtension
    }
}

public struct FolderComparer {
    /// Names never compared.
    public var ignoredNames: Set<String> = [".DS_Store"]
    /// Text files larger than this are only checked for identical bytes, not diffed.
    public var diffCountLimit = 4 * 1024 * 1024
    public var options: CompareOptions
    public var filter: FileFilter

    public init(options: CompareOptions = .standard, filter: FileFilter = .all) {
        self.options = options
        self.filter = filter
    }

    /// Compares two folders recursively. `progress` is called with the number of files compared so far.
    public func compare(left: URL, right: URL, progress: ((Int) -> Void)? = nil, isCancelled: () -> Bool = { false }) -> [FolderItem] {
        var count = 0
        return compareFolder(left: left, right: right, relative: "", count: &count, progress: progress, isCancelled: isCancelled)
    }

    private struct Entry {
        var url: URL
        var isDirectory: Bool
        var stat: FileStat
    }

    private func list(_ url: URL?) -> [String: Entry] {
        guard let url else { return [:] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return [:] }
        var result: [String: Entry] = [:]
        for item in urls where !ignoredNames.contains(item.lastPathComponent) {
            let values = try? item.resourceValues(forKeys: Set(keys))
            // Do not follow symbolic links to folders, to avoid loops.
            let isDir = (values?.isDirectory ?? false) && !(values?.isSymbolicLink ?? false)
            let name = item.lastPathComponent
            guard isDir ? filter.includesFolder(named: name) : filter.includesFile(named: name) else { continue }
            result[item.lastPathComponent] = Entry(
                url: item,
                isDirectory: isDir,
                stat: FileStat(size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate))
        }
        return result
    }

    private func compareFolder(left: URL?, right: URL?, relative: String, count: inout Int, progress: ((Int) -> Void)?, isCancelled: () -> Bool) -> [FolderItem] {
        let l = list(left), r = list(right)
        var names = Set(l.keys).union(r.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // Folders first, like Finder's "folders on top".
        names.sort { a, b in
            let da = (l[a]?.isDirectory ?? r[a]?.isDirectory) ?? false
            let db = (l[b]?.isDirectory ?? r[b]?.isDirectory) ?? false
            return da && !db
        }
        var items: [FolderItem] = []
        for name in names {
            if isCancelled() { break }
            let le = l[name], re = r[name]
            let path = relative.isEmpty ? name : relative + "/" + name
            // A file on one side and a folder on the other are shown as two separate rows.
            if let le, let re, le.isDirectory != re.isDirectory {
                items.append(makeItem(path, name, le, nil, &count, progress, isCancelled))
                items.append(makeItem(path + "\u{0}r", name, nil, re, &count, progress, isCancelled))
                continue
            }
            items.append(makeItem(path, name, le, re, &count, progress, isCancelled))
        }
        return items
    }

    private func makeItem(_ id: String, _ name: String, _ le: Entry?, _ re: Entry?, _ count: inout Int, _ progress: ((Int) -> Void)?, _ isCancelled: () -> Bool) -> FolderItem {
        let isDir = (le?.isDirectory ?? re?.isDirectory) ?? false
        var item = FolderItem(id: id, name: name, isDirectory: isDir, left: le?.stat, right: re?.stat, result: .identical, children: nil)
        let relative = id.replacingOccurrences(of: "\u{0}r", with: "")
        if isDir {
            let children = compareFolder(left: le?.url, right: re?.url, relative: relative, count: &count, progress: progress, isCancelled: isCancelled)
            item.children = children
            if le == nil { item.result = .rightOnly }
            else if re == nil { item.result = .leftOnly }
            else { item.result = children.contains { $0.result.isDifferent } ? .different(diffCount: nil) : .identical }
        } else {
            if le == nil { item.result = .rightOnly }
            else if re == nil { item.result = .leftOnly }
            else if let le, let re { item.result = compareFiles(le, re) }
            count += 1
            progress?(count)
        }
        return item
    }

    private func compareFiles(_ l: Entry, _ r: Entry) -> CompareResult {
        do {
            let ld = try Data(contentsOf: l.url, options: .mappedIfSafe)
            let rd = try Data(contentsOf: r.url, options: .mappedIfSafe)
            let binary = TextFile.looksBinary(ld) || TextFile.looksBinary(rd)
            if ld == rd { return binary ? .binaryIdentical : .identical }
            if binary { return .binaryDifferent }
            guard ld.count + rd.count <= diffCountLimit else { return .different(diffCount: nil) }
            let lt = TextFile.decode(ld), rt = TextFile.decode(rd)
            if lt.isBinary || rt.isBinary { return .binaryDifferent }
            let hunks = LineComparison(left: splitLines(lt.text), right: splitLines(rt.text), options: options).hunks.count
            guard hunks == 0 else { return .different(diffCount: hunks) }
            // The text matches. The bytes can still differ in line endings or encoding,
            // or only in ways the options ignore.
            if lt.lineEnding != rt.lineEnding, !options.ignoreLineEndings, lt.text.contains("\n") || rt.text.contains("\n") {
                return .different(diffCount: 0)
            }
            if lt.encoding != rt.encoding || lt.hasBOM != rt.hasBOM {
                return .different(diffCount: 0)
            }
            return .identical
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
