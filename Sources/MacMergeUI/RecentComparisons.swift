import AppKit
import SwiftUI

/// The comparisons opened most recently, newest first.
@MainActor
final class RecentComparisons: ObservableObject {
    static let shared = RecentComparisons()
    private static let key = "recentComparisons"
    private static let limit = 15

    @Published private(set) var items: [CompareTarget] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([CompareTarget].self, from: data) {
            items = list
        }
    }

    func add(_ target: CompareTarget) {
        // Temporary files (such as clipboard comparisons) are not worth remembering.
        guard !target.left.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        items.removeAll { $0 == target }
        items.insert(target, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.key)
    }
}

/// Remembers the last two texts copied to the clipboard while MacMerge runs,
/// so they can be compared (like WinMerge's clipboard compare).
@MainActor
final class ClipboardHistory {
    static let shared = ClipboardHistory()
    private(set) var texts: [String] = []
    private var changeCount = -1
    private var timer: Timer?

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardHistory.shared.check() }
        }
    }

    func check() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty, text != texts.last else { return }
        texts.append(text)
        if texts.count > 2 { texts.removeFirst() }
    }

    /// Writes the two texts to temporary files and returns a comparison of them,
    /// or nil after telling the user that two texts are needed.
    func makeComparison() -> CompareTarget? {
        check()
        guard texts.count == 2 else {
            let alert = NSAlert()
            alert.messageText = L("Copy two texts first")
            alert.informativeText = L("MacMerge compares the last two texts you copied while it was running.")
            alert.runModal()
            return nil
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacMerge Clipboard \(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let older = dir.appendingPathComponent(L("Earlier Copy") + ".txt")
        let newer = dir.appendingPathComponent(L("Latest Copy") + ".txt")
        do {
            try texts[0].write(to: older, atomically: true, encoding: .utf8)
            try texts[1].write(to: newer, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
        return CompareTarget(left: older, right: newer, kind: .files)
    }
}
