import CryptoKit
import Foundation

public enum CompareResult: Equatable {
    case identical
    case different(diffCount: Int?)
    case leftOnly
    case rightOnly
    case binaryIdentical
    case binaryDifferent
    case error(String)
    /// A file that exists on one side only, but with the same contents as a file at
    /// `counterpart` (a path relative to the other root): it was renamed or moved.
    case moved(counterpart: String)
    /// A folder that exists on both sides but was not looked into (subfolders turned off).
    case notCompared

    public var isDifferent: Bool {
        switch self {
        case .identical, .binaryIdentical, .notCompared: return false
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
    /// Pair up files that exist on one side only but have identical contents.
    public var detectRenames: Bool
    /// Look into subfolders. When false, only the top level is compared.
    public var recursive = true

    public init(options: CompareOptions = .standard, filter: FileFilter = .all, detectRenames: Bool = false) {
        self.options = options
        self.filter = filter
        self.detectRenames = detectRenames
    }

    /// Compares two folders recursively. `progress` is called with the number of files compared so far.
    public func compare(left: URL, right: URL, progress: ((Int) -> Void)? = nil, isCancelled: () -> Bool = { false }) -> [FolderItem] {
        var count = 0
        var items = compareFolder(left: left, right: right, relative: "", count: &count, progress: progress, isCancelled: isCancelled)
        if detectRenames { Self.markRenames(&items, left: left, right: right) }
        return items
    }

    /// Marks one-sided files whose contents match exactly one file on the other side.
    static func markRenames(_ items: inout [FolderItem], left: URL, right: URL) {
        var leftOnly: [String: FileStat] = [:], rightOnly: [String: FileStat] = [:]
        func collect(_ list: [FolderItem], _ side: CompareResult?) {
            for item in list {
                let s = item.result == .leftOnly || item.result == .rightOnly ? item.result : side
                if let children = item.children { collect(children, s); continue }
                let path = item.id.replacingOccurrences(of: "\u{0}r", with: "")
                if s == .leftOnly, let stat = item.left { leftOnly[path] = stat }
                if s == .rightOnly, let stat = item.right { rightOnly[path] = stat }
            }
        }
        collect(items, nil)
        guard !leftOnly.isEmpty, !rightOnly.isEmpty else { return }

        func hash(_ url: URL) -> String? {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let rightSizes = Set(rightOnly.values.map(\.size))
        var leftByHash: [String: [String]] = [:], rightByHash: [String: [String]] = [:]
        for (path, stat) in leftOnly where stat.size > 0 && rightSizes.contains(stat.size) {
            if let h = hash(left.appending(path: path)) { leftByHash[h, default: []].append(path) }
        }
        let leftSizes = Set(leftOnly.values.map(\.size))
        for (path, stat) in rightOnly where stat.size > 0 && leftSizes.contains(stat.size) {
            if let h = hash(right.appending(path: path)) { rightByHash[h, default: []].append(path) }
        }
        var pairs: [String: String] = [:], reverse: [String: String] = [:]
        for (h, lefts) in leftByHash where lefts.count == 1 {
            guard let rights = rightByHash[h], rights.count == 1 else { continue }
            pairs[lefts[0]] = rights[0]
            reverse[rights[0]] = lefts[0]
        }
        func apply(_ list: inout [FolderItem]) {
            for i in list.indices {
                if list[i].children != nil {
                    apply(&list[i].children!)
                    continue
                }
                let path = list[i].id.replacingOccurrences(of: "\u{0}r", with: "")
                if list[i].left != nil, list[i].right == nil, let other = pairs[path] { list[i].result = .moved(counterpart: other) }
                if list[i].right != nil, list[i].left == nil, let other = reverse[path] { list[i].result = .moved(counterpart: other) }
            }
        }
        apply(&items)
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
        if isDir, !recursive {
            if le == nil { item.result = .rightOnly } else if re == nil { item.result = .leftOnly } else { item.result = .notCompared }
        } else if isDir {
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
