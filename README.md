# MacMerge

WinMerge にインスパイアされた、macOS 向けのオープンソースのファイル・フォルダ比較ツールです。

A free, open-source file and folder comparison tool for macOS, inspired by WinMerge.

> 🚧 開発中です / Work in progress

## 予定している機能 / Planned features

- [ ] ファイルの左右比較（差分の色分け表示）/ Side-by-side file comparison
- [ ] 行内の差分表示 / Inline (character-level) differences
- [ ] 差分の左右コピー・その場で編集・保存 / Copy changes left/right, edit and save
- [ ] フォルダ比較 / Folder comparison

## ビルド / Build

macOS 14 以降、Xcode 16 以降が必要です。

```bash
swift build
swift run MacMerge
swift test
```

## WinMerge との関係 / Relationship to WinMerge

MacMerge は WinMerge の使い勝手を参考にした独立したプロジェクトで、WinMerge のソースコードは含んでいません。WinMerge 開発チームとは無関係です。

MacMerge is an independent project inspired by WinMerge's workflow. It contains no WinMerge source code and is not affiliated with the WinMerge project.

## ライセンス / License

[MIT](LICENSE)
