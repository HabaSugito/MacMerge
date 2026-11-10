import SwiftUI

/// Menu bar commands. Shortcuts follow WinMerge, with Alt mapped to Option.
struct AppCommands: Commands {
    @FocusedValue(\.fileCompare) private var compare
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新しい比較…") { openWindow(id: "open") }
                .keyboardShortcut("n")
        }

        CommandGroup(replacing: .saveItem) {
            Button("保存") { compare?.saveAll() }
                .keyboardShortcut("s")
                .disabled(compare == nil)
            Button("左を保存") { compare?.save(.left) }
                .disabled(compare == nil)
            Button("右を保存") { compare?.save(.right) }
                .disabled(compare == nil)
            Divider()
            Button("再読み込み") { compare?.reload() }
                .keyboardShortcut("r")
                .disabled(compare == nil)
        }

        CommandGroup(after: .toolbar) {
            Toggle("行内の差分を表示", isOn: Binding(
                get: { compare?.showsInlineDifferences ?? true },
                set: { compare?.showsInlineDifferences = $0 }))
                .disabled(compare == nil)
        }

        CommandMenu("マージ") {
            Button("次の差分") { compare?.nextDifference() }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("前の差分") { compare?.previousDifference() }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("最初の差分") { compare?.firstDifference() }
                .keyboardShortcut(.home, modifiers: .option)
            Button("最後の差分") { compare?.lastDifference() }
                .keyboardShortcut(.end, modifiers: .option)
            Button("現在の差分") { compare?.currentDifference() }
                .keyboardShortcut(.return, modifiers: .option)
            Divider()
            Button("右へコピー") { compare?.copyCurrent(from: .left) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
            Button("左へコピー") { compare?.copyCurrent(from: .right) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("右へコピーして次へ") { compare?.copyCurrent(from: .left, advance: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
            Button("左へコピーして次へ") { compare?.copyCurrent(from: .right, advance: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
            Divider()
            Button("すべて右へコピー") { compare?.copyAll(from: .left) }
            Button("すべて左へコピー") { compare?.copyAll(from: .right) }
        }
    }
}
