import AppKit
import DiffCore
import SwiftUI

/// Menu bar commands. Shortcuts follow WinMerge, with Alt mapped to Option.
struct AppCommands: Commands {
    @FocusedValue(\.fileCompare) private var compare
    @FocusedValue(\.folderCompare) private var folder
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var recent = RecentComparisons.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Comparison…") { openWindow(id: "open") }
                .keyboardShortcut("n")
            Button("Open Conflict File…") { openConflictFile() }
            Button("Compare Clipboard History") {
                if let target = ClipboardHistory.shared.makeComparison() { openWindow(value: target) }
            }
            Menu("Open Recent") {
                ForEach(recent.items, id: \.self) { target in
                    Button(target.title) { openWindow(value: target) }
                }
                Divider()
                Button("Clear Menu") { recent.clear() }
                    .disabled(recent.items.isEmpty)
            }
            Divider()
            Button("Open Project…") { openProject() }
                .keyboardShortcut("o")
            Button("Save as Project…") {
                if let target = compare?.target ?? folder?.target { ProjectFile.save(target) }
            }
            .disabled(compare == nil && folder == nil)
            Divider()
            Button("Open in Default App") { compare.map { $0.openExternally(pane: $0.activePane, choosingApp: false) } }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(compare == nil)
            Button("Open With…") { compare.map { $0.openExternally(pane: $0.activePane, choosingApp: true) } }
                .disabled(compare == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                let html = compare?.makeReport() ?? folder?.makeReport()
                if let html { ReportPrinter.print(html: html, from: NSApp.keyWindow) }
            }
            .keyboardShortcut("p")
            .disabled(compare == nil && folder == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { compare?.saveAll() }
                .keyboardShortcut("s")
                .disabled(compare == nil)
            Button("Save Left") { compare?.save(pane: 0) }
                .disabled(compare == nil)
            if compare?.isThreeWay == true {
                Button("Save Middle") { compare?.save(pane: 1) }
            }
            Button("Save Right") { compare.map { $0.save(pane: $0.paneCount - 1) } }
                .disabled(compare == nil)
            Divider()
            Menu("Line Endings") {
                ForEach(LineEnding.allCases, id: \.self) { ending in
                    Toggle(ending.rawValue, isOn: Binding(
                        get: { compare.map { $0.info[$0.activePane].file.lineEnding == ending } ?? false },
                        set: { _ in compare.map { $0.setLineEnding(ending, pane: $0.activePane) } }))
                }
            }
            .disabled(compare == nil)
            Menu("Save with Encoding") {
                ForEach(TextFile.menuEncodings, id: \.name) { item in
                    Toggle(item.name, isOn: Binding(
                        get: { compare.map { $0.info[$0.activePane].file.encoding == item.encoding && $0.info[$0.activePane].file.hasBOM == item.bom } ?? false },
                        set: { _ in compare.map { $0.setEncoding(item.encoding, bom: item.bom, pane: $0.activePane) } }))
                }
            }
            .disabled(compare == nil)
            Menu("Reopen with Encoding") {
                ForEach(TextFile.menuEncodings.filter { !$0.bom || $0.encoding != .utf8 }, id: \.name) { item in
                    Button(item.name) { compare.map { $0.reopen(pane: $0.activePane, as: item.encoding) } }
                }
            }
            .disabled(compare == nil)
            Divider()
            Button("Reload") {
                if let compare { compare.reload() } else { folder?.compare() }
            }
            .keyboardShortcut("r")
            .disabled(compare == nil && folder == nil)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Go to Line…") { compare?.promptGoToLine() }
                .keyboardShortcut("l")
                .disabled(compare == nil)
            Menu("Bookmarks") {
                Button("Toggle Bookmark") { compare?.toggleBookmark() }
                    .keyboardShortcut(Self.functionKey(NSF2FunctionKey), modifiers: .command)
                Button("Next Bookmark") { compare?.nextBookmark() }
                    .keyboardShortcut(Self.functionKey(NSF2FunctionKey), modifiers: [])
                Button("Previous Bookmark") { compare?.nextBookmark(forward: false) }
                    .keyboardShortcut(Self.functionKey(NSF2FunctionKey), modifiers: .shift)
                Button("Clear All Bookmarks") { compare?.clearBookmarks() }
            }
            .disabled(compare == nil)
        }

        CommandGroup(after: .toolbar) {
            Toggle("Wrap Lines", isOn: Binding(
                get: { compare?.wrapLines ?? false },
                set: { compare?.wrapLines = $0 }))
                .disabled(compare == nil)
            Button("Swap Left and Right") { compare?.swapSides() }
                .disabled(compare == nil)
            Menu("Read Only") {
                if let compare {
                    ForEach(0..<compare.paneCount, id: \.self) { p in
                        Toggle(paneName(p, of: compare.paneCount), isOn: Binding(
                            get: { compare.info[p].isReadOnly },
                            set: { compare.setReadOnly($0, pane: p) }))
                    }
                }
            }
            .disabled(compare == nil)
            Divider()
            Toggle("Show Differences Within Lines", isOn: Binding(
                get: { compare?.showsInlineDifferences ?? true },
                set: { compare?.showsInlineDifferences = $0 }))
                .disabled(compare == nil)
            Picker("Lines Around Differences", selection: Binding(
                get: { compare?.diffContext ?? -1 },
                set: { compare?.diffContext = $0 < 0 ? nil : $0 })) {
                Text("All Lines").tag(-1)
                ForEach([0, 1, 3, 5, 7, 9], id: \.self) { Text("\($0) Lines").tag($0) }
            }
            .disabled(compare == nil)
            Button("Toggle All Lines / Lines Around Differences") {
                guard let compare else { return }
                compare.diffContext = compare.diffContext == nil ? DiffContextSetting.lastNumber : nil
            }
            .keyboardShortcut("d")
            .disabled(compare == nil)
        }

        CommandMenu("Merge") {
            Toggle("Merge Mode", isOn: Binding(
                get: { compare?.mergeMode ?? false },
                set: { compare?.mergeMode = $0 }))
                .keyboardShortcut(Self.functionKey(NSF9FunctionKey), modifiers: [])
                .disabled(compare == nil)
            Divider()
            Button("Next Difference") { compare?.nextDifference() }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Previous Difference") { compare?.previousDifference() }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Next Conflict") { compare?.nextDifference(conflictsOnly: true) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
                .disabled(compare?.isThreeWay != true)
            Button("Previous Conflict") { compare?.previousDifference(conflictsOnly: true) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
                .disabled(compare?.isThreeWay != true)
            Button("First Difference") { compare?.firstDifference() }
                .keyboardShortcut(.home, modifiers: .option)
            Button("Last Difference") { compare?.lastDifference() }
                .keyboardShortcut(.end, modifiers: .option)
            Button("Current Difference") { compare?.currentDifference() }
                .keyboardShortcut(.return, modifiers: .option)
            Divider()
            Button(compare?.isThreeWay == true ? "Take Left into Middle" : "Copy to Right") {
                if let compare { compare.copyRightward() } else { folder?.copySelected(toRight: true) }
            }
            .keyboardShortcut(.rightArrow, modifiers: .option)
            Button(compare?.isThreeWay == true ? "Take Right into Middle" : "Copy to Left") {
                if let compare { compare.copyLeftward() } else { folder?.copySelected(toRight: false) }
            }
            .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("Copy to Right and Advance") { compare?.copyRightward(advance: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
            Button("Copy to Left and Advance") { compare?.copyLeftward(advance: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
            Divider()
            Button("Copy All to Right") { compare.map { $0.copyAll(from: $0.rightwardPanes.from, to: $0.rightwardPanes.to) } }
            Button("Copy All to Left") { compare.map { $0.copyAll(from: $0.leftwardPanes.from, to: $0.leftwardPanes.to) } }
            Button("Add Synchronization Point") { compare?.addSyncPoint() }
                .keyboardShortcut("s", modifiers: [.control, .option])
                .disabled(compare == nil || compare?.isThreeWay == true)
            Button("Clear Synchronization Points") { compare?.clearSyncPoints() }
                .disabled(compare?.syncPoints.isEmpty ?? true)
            Button("Auto Merge") { compare?.autoMerge() }
                .keyboardShortcut("m", modifiers: [.control, .option])
                .disabled(compare?.isThreeWay != true)
            Divider()
            Button("Move to Trash…") { folder?.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(folder == nil)
        }

        CommandMenu("Tools") {
            Button("Create HTML Report…") {
                if let compare { Exporter.saveReport(compare.makeReport()) } else if let folder { Exporter.saveReport(folder.makeReport()) }
            }
            .disabled(compare == nil && folder == nil)
            Button("Create Patch…") {
                if let compare { Exporter.savePatch(compare.makePatch()) } else if let folder { Exporter.savePatch(folder.makePatch()) }
            }
            .disabled((compare == nil || compare?.isThreeWay == true) && folder == nil)
        }
    }

    private static func functionKey(_ code: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt16(code))!))
    }

    private func paneName(_ p: Int, of count: Int) -> LocalizedStringKey {
        if count == 3, p == 1 { return "Middle" }
        return p == 0 ? "Left" : "Right"
    }

    private func openConflictFile() {
        let panel = NSOpenPanel()
        panel.message = L("Choose a file that contains Git conflict markers (<<<<<<<)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(value: CompareTarget.conflict(url))
    }

    private func openProject() {
        guard let target = ProjectFile.open() else { return }
        openWindow(value: target)
    }
}
