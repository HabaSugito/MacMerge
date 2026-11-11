import AppKit
import SwiftUI

/// Menu bar commands. Shortcuts follow WinMerge, with Alt mapped to Option.
struct AppCommands: Commands {
    @FocusedValue(\.fileCompare) private var compare
    @FocusedValue(\.folderCompare) private var folder
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新しい比較…") { openWindow(id: "open") }
                .keyboardShortcut("n")
            Button("コンフリクトファイルを開く…") { openConflictFile() }
            Divider()
            Button("プロジェクトを開く…") { openProject() }
                .keyboardShortcut("o")
            Button("プロジェクトとして保存…") {
                if let target = compare?.target ?? folder?.target { ProjectFile.save(target) }
            }
            .disabled(compare == nil && folder == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("保存") { compare?.saveAll() }
                .keyboardShortcut("s")
                .disabled(compare == nil)
            Button("左を保存") { compare?.save(pane: 0) }
                .disabled(compare == nil)
            if compare?.isThreeWay == true {
                Button("中央を保存") { compare?.save(pane: 1) }
            }
            Button("右を保存") { compare.map { $0.save(pane: $0.paneCount - 1) } }
                .disabled(compare == nil)
            Divider()
            Button("再読み込み") {
                if let compare { compare.reload() } else { folder?.compare() }
            }
            .keyboardShortcut("r")
            .disabled(compare == nil && folder == nil)
        }

        CommandGroup(after: .toolbar) {
            Toggle("行内の差分を表示", isOn: Binding(
                get: { compare?.showsInlineDifferences ?? true },
                set: { compare?.showsInlineDifferences = $0 }))
                .disabled(compare == nil)
            Picker("差分の前後に表示する行", selection: Binding(
                get: { compare?.diffContext ?? -1 },
                set: { compare?.diffContext = $0 < 0 ? nil : $0 })) {
                Text("すべての行").tag(-1)
                ForEach([0, 1, 3, 5, 7, 9], id: \.self) { Text("\($0) 行").tag($0) }
            }
            .disabled(compare == nil)
            Button("すべての行 ⇄ 差分の前後だけ") {
                guard let compare else { return }
                compare.diffContext = compare.diffContext == nil ? DiffContextSetting.lastNumber : nil
            }
            .keyboardShortcut("d")
            .disabled(compare == nil)
        }

        CommandMenu("マージ") {
            Button("次の差分") { compare?.nextDifference() }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("前の差分") { compare?.previousDifference() }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("次のコンフリクト") { compare?.nextDifference(conflictsOnly: true) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
                .disabled(compare?.isThreeWay != true)
            Button("前のコンフリクト") { compare?.previousDifference(conflictsOnly: true) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
                .disabled(compare?.isThreeWay != true)
            Button("最初の差分") { compare?.firstDifference() }
                .keyboardShortcut(.home, modifiers: .option)
            Button("最後の差分") { compare?.lastDifference() }
                .keyboardShortcut(.end, modifiers: .option)
            Button("現在の差分") { compare?.currentDifference() }
                .keyboardShortcut(.return, modifiers: .option)
            Divider()
            Button(compare?.isThreeWay == true ? "左から中央へ取り込む" : "右へコピー") {
                if let compare { compare.copyRightward() } else { folder?.copySelected(toRight: true) }
            }
            .keyboardShortcut(.rightArrow, modifiers: .option)
            Button(compare?.isThreeWay == true ? "右から中央へ取り込む" : "左へコピー") {
                if let compare { compare.copyLeftward() } else { folder?.copySelected(toRight: false) }
            }
            .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("右へコピーして次へ") { compare?.copyRightward(advance: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
            Button("左へコピーして次へ") { compare?.copyLeftward(advance: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
            Divider()
            Button("すべて右へコピー") { compare.map { $0.copyAll(from: $0.rightwardPanes.from, to: $0.rightwardPanes.to) } }
            Button("すべて左へコピー") { compare.map { $0.copyAll(from: $0.leftwardPanes.from, to: $0.leftwardPanes.to) } }
            Button("自動マージ") { compare?.autoMerge() }
                .keyboardShortcut("m", modifiers: [.control, .option])
                .disabled(compare?.isThreeWay != true)
            Divider()
            Button("ゴミ箱に入れる…") { folder?.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(folder == nil)
        }

        CommandMenu("ツール") {
            Button("HTML レポートを作成…") {
                if let compare { Exporter.saveReport(compare.makeReport()) } else if let folder { Exporter.saveReport(folder.makeReport()) }
            }
            .disabled(compare == nil && folder == nil)
            Button("パッチを作成…") {
                if let compare { Exporter.savePatch(compare.makePatch()) } else if let folder { Exporter.savePatch(folder.makePatch()) }
            }
            .disabled((compare == nil || compare?.isThreeWay == true) && folder == nil)
        }
    }

    private func openConflictFile() {
        let panel = NSOpenPanel()
        panel.message = "Git のコンフリクトの印（<<<<<<<）が入ったファイルを選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(value: CompareTarget.conflict(url))
    }

    private func openProject() {
        guard let target = ProjectFile.open() else { return }
        openWindow(value: target)
    }
}
