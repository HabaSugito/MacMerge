import Foundation

public enum FileOperations {
    /// Copies a file or folder to `destination`. An existing file is replaced; an existing
    /// folder is merged, so files only in the destination are kept (like WinMerge).
    public static func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isDir.boolValue {
            var destIsDir: ObjCBool = false
            if fm.fileExists(atPath: destination.path, isDirectory: &destIsDir), !destIsDir.boolValue {
                try fm.removeItem(at: destination)
            }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copy(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: try temporaryCopy(of: source, near: destination))
            } else {
                try fm.copyItem(at: source, to: destination)
            }
        }
    }

    /// Moves a file or folder to the Trash so it can be recovered.
    public static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private static func temporaryCopy(of source: URL, near destination: URL) throws -> URL {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).macmerge-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: temp)
        return temp
    }
}
