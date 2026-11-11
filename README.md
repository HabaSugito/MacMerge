# MacMerge

WinMerge にインスパイアされた、macOS 向けのオープンソースのファイル・フォルダ比較ツールです。

A free, open-source file and folder comparison tool for macOS, inspired by WinMerge.

> 🚧 開発中です / Work in progress

## できること / Features

**ファイル比較 / File compare**
- 左右に並べて比較し、差分を色分け表示（片側にしかない行は灰色の空行でそろえる）
- 行内の差分表示（単語単位。日本語は1文字ずつ区切る）
- 差分の場所を示すロケーションペイン（クリックで移動）
- 差分の左右コピー、その場で編集、元に戻す、保存
- 文字コード（UTF-8 / UTF-16 / Shift_JIS / EUC-JP）と改行コード（LF / CRLF / CR）を自動判定し、保存時は元の形式のまま書き戻す
- 差分ブロックの中では、似ている行同士を同じ高さにそろえる
- 差分の前後だけ表示（0〜9行。⌘D で「すべての行」と切り替え）
- 移動した行の検出（オレンジで表示）
- HTML レポートとパッチ（unified 形式）の書き出し

**3者比較とマージ / 3-way compare and merge**
- 左・ベース（中央）・右の3ペインで比較。片側だけの変更は青、両側が別々に変えたコンフリクトは黄色
- 自動マージ（⌃⌥M）：片側だけの変更をまとめて中央へ取り込み、コンフリクトだけを残す
- Git のコンフリクトファイル（`<<<<<<<` の印つき）を開いて、自分の変更・結果・相手の変更に分けて表示

**フォルダ比較 / Folder compare**
- サブフォルダを含めて中身で比較し、ツリー表示
- 「同一」「異なる」「左のみ」「右のみ」で表示を絞り込み
- ダブルクリックでファイル比較を開く
- 列見出しのクリックで並べ替え
- 選択した項目を左右へコピー、ゴミ箱に入れる
- ファイルフィルタ（例: `*.swift;*.txt;!*.o;!build/`。`!` で除外、末尾 `/` でフォルダ）
- フォルダ全体のパッチと HTML レポートの書き出し

**プロジェクトファイル / Project files**
- 比較するパス・フィルタ・比較オプションを `.macmerge` ファイルに保存し、あとで開き直せる（⌘O）

**比較オプション / Compare options**（ツールバーの調整ボタン、または 設定 ⌘,）
- 空白：比較する / 量の違いを無視 / すべて無視
- 大文字と小文字を無視、空行を無視、改行コードの違いを無視、移動した行を検出
- 行フィルタ：正規表現に当てはまる行だけの差分を無視（設定画面）
- 無視した差分は差分として数えず、薄い色で表示

## 使い方 / Usage

### キーボードショートカット

WinMerge の Alt を Option（⌥）に置き換えています。

| 操作 | ショートカット |
| --- | --- |
| 次の差分 / 前の差分 | ⌥↓ / ⌥↑ |
| 最初の差分 / 最後の差分 | ⌥Home / ⌥End |
| 右へコピー / 左へコピー | ⌥→ / ⌥← |
| コピーして次の差分へ | ⌃⌥→ / ⌃⌥← |
| 次のコンフリクト / 前のコンフリクト（3者比較） | ⌥⇧↓ / ⌥⇧↑ |
| 自動マージ（3者比較） | ⌃⌥M |
| すべての行 ⇄ 差分の前後だけ | ⌘D |
| 選択項目をゴミ箱へ（フォルダ比較） | ⌘⌫ |
| 保存 | ⌘S |
| 再読み込み | ⌘R |
| 新しい比較 | ⌘N |
| プロジェクトを開く | ⌘O |

### コマンドラインから開く

```bash
build/MacMerge.app/Contents/MacOS/MacMerge 左のパス 右のパス
```

| 引数 | 開くもの |
| --- | --- |
| `左 右` | 2つのファイルまたはフォルダを比較 |
| `左 ベース 右 [保存先]` | 3者比較。中央のペインを保存先（省略時はベース）に保存 |
| `ファイル` | Git のコンフリクトファイルを開く |

`git difftool` / `git mergetool` で使う例:

```bash
git config --global difftool.macmerge.cmd '/Applications/MacMerge.app/Contents/MacOS/MacMerge "$LOCAL" "$REMOTE"'
git config --global mergetool.macmerge.cmd '/Applications/MacMerge.app/Contents/MacOS/MacMerge "$LOCAL" "$BASE" "$REMOTE" "$MERGED"'
git config --global mergetool.macmerge.trustExitCode false
git difftool -t macmerge
git mergetool -t macmerge
```

## ビルド / Build

macOS 14 以降、Xcode 16 以降が必要です。

```bash
./scripts/build-app.sh   # build/MacMerge.app を作る
swift test               # 比較エンジンのテスト
```

### 開発用の環境変数

画面録画の権限なしで動作を確かめるための機能です。

- `MACMERGE_SNAPSHOT=/path/prefix`：起動の数秒後に各ウィンドウを PNG で保存（`MACMERGE_SNAPSHOT_DELAY` で秒数を指定）
- `MACMERGE_ACTIONS=next,copyRight,saveRight`：最初のファイル比較で操作を自動実行

## WinMerge との関係 / Relationship to WinMerge

MacMerge は WinMerge の使い勝手を参考にした独立したプロジェクトで、WinMerge のソースコードは含んでいません。WinMerge 開発チームとは無関係です。

MacMerge is an independent project inspired by WinMerge's workflow. It contains no WinMerge source code and is not affiliated with the WinMerge project.

## ライセンス / License

[MIT](LICENSE)
