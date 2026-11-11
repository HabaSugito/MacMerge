import AppKit
import SwiftUI

/// Program entry. AppKit opens no window at all when launched with plain arguments,
/// so `MacMerge left right` restarts itself as `MacMerge -MacMergeLeft left -MacMergeRight right`,
/// which AppKit reads as settings instead.
public enum Launcher {
    public static func main() {
        LaunchArguments.relaunchWithOptionsIfNeeded()
        MacMergeApp.main()
    }
}

enum LaunchArguments {
    static var consumed = false
    private static let keys = ["MacMergeLeft", "MacMergeMiddle", "MacMergeRight", "MacMergeOutput", "MacMergeConflict"]

    /// The comparison asked for on the command line:
    /// `MacMerge FILE` (conflict file), `MacMerge LEFT RIGHT`, `MacMerge LEFT BASE RIGHT [OUTPUT]`.
    static var target: CompareTarget? {
        let options = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        func url(_ key: String) -> URL? { (options[key] as? String).map { URL(filePath: $0) } }
        if let conflict = url("MacMergeConflict") { return .conflict(conflict) }
        guard let left = url("MacMergeLeft"), let right = url("MacMergeRight") else { return nil }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: left.path, isDirectory: &isDir)
        return CompareTarget(left: left, right: right, middle: url("MacMergeMiddle"), output: url("MacMergeOutput"),
                             kind: isDir.boolValue ? .folders : .files)
    }

    static func relaunchWithOptionsIfNeeded() {
        let args = Array(CommandLine.arguments.dropFirst())
        var options: [String] = []
        var positional: [String] = []
        var i = 0
        while i < args.count {
            if args[i].hasPrefix("-") {
                options.append(args[i])
                if i + 1 < args.count { options.append(args[i + 1]) }
                i += 2
            } else {
                positional.append(args[i])
                i += 1
            }
        }
        guard (1...4).contains(positional.count), let exe = Bundle.main.executablePath else { return }
        let cwd = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
        let paths = positional.map { URL(filePath: ($0 as NSString).expandingTildeInPath, relativeTo: cwd).path(percentEncoded: false) }
        let names: [String]
        switch paths.count {
        case 1: names = ["MacMergeConflict"]
        case 2: names = ["MacMergeLeft", "MacMergeRight"]
        default: names = ["MacMergeLeft", "MacMergeMiddle", "MacMergeRight", "MacMergeOutput"]
        }
        var newArgs = [exe] + options
        for (name, path) in zip(names, paths) { newArgs += ["-" + name, path] }
        var cArgs = newArgs.map { strdup($0) } + [nil]
        execv(exe, &cArgs)
        // execv only returns on failure; carry on without the paths.
    }
}

struct MacMergeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Like WinMerge, everything lives in tabs of one window: a new tab shows the
        // open form, and comparing turns that tab into the comparison.
        WindowGroup("MacMerge", id: WindowSettings.groupID, for: CompareTarget.self) { $target in
            MainContent(target: $target)
                .background(WindowConfigurator())
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            AppCommands()
            TextEditingCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// The content of one tab: the open form until something is compared, then the comparison.
struct MainContent: View {
    @Binding var target: CompareTarget?

    var body: some View {
        if let target {
            Group {
                if target.isFolder {
                    FolderCompareView(target: target)
                } else {
                    FileCompareView(target: target)
                }
            }
            .id(target)
            .frame(minWidth: 700, minHeight: 400)
        } else {
            OpenView(target: $target)
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}

/// Whether comparisons open as tabs of one window (the default, like WinMerge) or in separate windows.
enum WindowSettings {
    static let groupID = "main"
    static let tabsKey = "window.openInTabs"

    static var opensInTabs: Bool { UserDefaults.standard.flag(tabsKey, default: true) }

    /// macOS's own per-app preference for tabs ("Prefer tabs when opening documents").
    static func applySystemPreference() {
        UserDefaults.standard.set(opensInTabs ? "always" : "manual", forKey: "AppleWindowTabbingMode")
    }
}

/// Puts each window into the shared tab group, or keeps it on its own, following the setting.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowHook() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowHook: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.tabbingIdentifier = "MacMerge"
            window.tabbingMode = WindowSettings.opensInTabs ? .preferred : .disallowed
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Do not restore the last session's windows. Restoring a session that ended with
        // no windows open would start the app with nothing on screen.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        WindowSettings.applySystemPreference()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started with `swift run` instead of from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        // Automated snapshot runs must not take the keyboard away from whatever the user is doing.
        if ProcessInfo.processInfo.environment["MACMERGE_SNAPSHOT"] == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        ClipboardHistory.shared.start()
        scheduleSnapshotIfRequested()
    }

    /// For development: `MACMERGE_SNAPSHOT=/path/prefix` saves PNGs of every window a few
    /// seconds after launch, so the UI can be checked without screen-recording permission.
    private func scheduleSnapshotIfRequested() {
        guard let prefix = ProcessInfo.processInfo.environment["MACMERGE_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["MACMERGE_SNAPSHOT_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let titles = NSApp.windows.map { "\($0.title) (visible: \($0.isVisible), tabs: \($0.tabbedWindows?.count ?? 1))" }
            FileHandle.standardError.write(Data("snapshot: windows \(titles)\n".utf8))
            for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                do {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-\(i).png"))
                } catch {
                    FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                }
            }
        }
    }
}
