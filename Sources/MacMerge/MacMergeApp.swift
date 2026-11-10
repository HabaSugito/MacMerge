import AppKit
import SwiftUI

/// Program entry. AppKit opens no window at all when launched with plain arguments,
/// so `MacMerge left right` restarts itself as `MacMerge -MacMergeLeft left -MacMergeRight right`,
/// which AppKit reads as settings instead.
@main
enum Launcher {
    static func main() {
        LaunchArguments.relaunchWithOptionsIfNeeded()
        MacMergeApp.main()
    }
}

enum LaunchArguments {
    static var consumed = false

    /// Paths given on the command line.
    static var paths: [String] {
        let options = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let left = options["MacMergeLeft"] as? String, let right = options["MacMergeRight"] as? String else { return [] }
        return [left, right]
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
        guard positional.count == 2, let exe = Bundle.main.executablePath else { return }
        let cwd = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
        let absolute = positional.map { URL(filePath: ($0 as NSString).expandingTildeInPath, relativeTo: cwd).path(percentEncoded: false) }
        let newArgs = [exe] + options + ["-MacMergeLeft", absolute[0], "-MacMergeRight", absolute[1]]
        var cArgs = newArgs.map { strdup($0) } + [nil]
        execv(exe, &cArgs)
        // execv only returns on failure; carry on without the paths.
    }
}

struct MacMergeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("MacMerge", id: "open") {
            OpenView()
        }
        .windowResizability(.contentSize)

        WindowGroup("比較", for: CompareTarget.self) { $target in
            if let target {
                Group {
                    if target.isFolder {
                        FolderCompareView(target: target)
                    } else {
                        FileCompareView(target: target)
                    }
                }
                .frame(minWidth: 700, minHeight: 400)
            } else {
                OpenView(closesAfterCompare: true)
            }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            AppCommands()
            TextEditingCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Do not restore the last session's windows. Restoring a session that ended with
        // no windows open would start the app with nothing on screen.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started with `swift run` instead of from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        scheduleSnapshotIfRequested()
    }

    /// For development: `MACMERGE_SNAPSHOT=/path/prefix` saves PNGs of every window a few
    /// seconds after launch, so the UI can be checked without screen-recording permission.
    private func scheduleSnapshotIfRequested() {
        guard let prefix = ProcessInfo.processInfo.environment["MACMERGE_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["MACMERGE_SNAPSHOT_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let titles = NSApp.windows.map { "\($0.title) (visible: \($0.isVisible))" }
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
