import SwiftUI

@main
struct MacMergeApp: App {
    var body: some Scene {
        WindowGroup("MacMerge") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("MacMerge").font(.largeTitle.bold())
            Text("ファイル・フォルダ比較ツール（開発中）")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
