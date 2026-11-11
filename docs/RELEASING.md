# リリースと公開の手順 / Releasing

MacMerge は次の2か所で公開します。

| もの | 置き場所 |
| --- | --- |
| アプリ（署名・公証済みの DMG） | GitHub Releases |
| 紹介ページ（`site/`） | Cloudflare Pages |

紹介ページの「ダウンロード」ボタンは
`https://github.com/HabaSugito/MacMerge/releases/latest/download/MacMerge.dmg`
を指しているので、新しいリリースを出すと自動で最新版に変わります。

---

## 1. 最初に一度だけする準備

### 1-1. Developer ID の証明書を作る

アプリの署名に使う「Developer ID Application」証明書です（Apple Developer Program のアカウント保有者の権限が必要です）。

1. Xcode を開き、**Settings → Accounts** でチームを選んで **Manage Certificates…** を押す
2. 左下の **＋** → **Developer ID Application** を選ぶ
3. キーチェーンアクセスで「Developer ID Application: あなたの名前 (チームID)」を探し、右クリック → **書き出す** で `.p12` ファイルとして保存する（パスワードを付ける）

証明書の正式な名前は次のコマンドで確認できます。

```bash
security find-identity -v -p codesigning
```

### 1-2. 公証用の API キーを作る

1. [App Store Connect](https://appstoreconnect.apple.com/) → **ユーザとアクセス → 統合 → App Store Connect API** を開く
2. **チームキー** を「Developer」の権限で作る
3. `.p8` ファイルをダウンロードする（**一度しかダウンロードできません**）
4. 画面に出る **キー ID** と **Issuer ID** を控える

### 1-3. GitHub に秘密情報を登録する

GitHub Actions が署名と公証に使います。リポジトリのフォルダで次を実行してください（値はプロンプトに貼り付けます）。

```bash
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERT_P12_BASE64
gh secret set DEVELOPER_ID_CERT_PASSWORD
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8_BASE64
gh secret set NOTARY_KEY_ID
gh secret set NOTARY_ISSUER
gh secret set SIGN_IDENTITY   # 例: Developer ID Application: Your Name (ABCDE12345)
```

登録が終わったら、`.p12` と `.p8` は安全な場所に保管し、ほかには置かないでください。

### 1-4. Cloudflare Pages に紹介ページをつなぐ

1. Cloudflare のダッシュボード → **Workers & Pages → 作成 → Pages → Git に接続**
2. `HabaSugito/MacMerge` を選ぶ
3. 設定：
   - プロジェクト名：`macmerge`（→ `https://macmerge.pages.dev`）
   - 本番ブランチ：`main`
   - フレームワーク：なし
   - ビルドコマンド：（空欄）
   - ビルド出力ディレクトリ：`site`
4. 独自ドメインを使う場合は、プロジェクトの **カスタムドメイン** から追加する

以後は `main` に `site/` の変更をプッシュするたびに自動で公開されます。

> プロジェクト名を `macmerge` 以外にした場合や独自ドメインを使う場合は、`site/index.html` と `site/ja/index.html` の `macmerge.pages.dev` を実際のアドレスに書き換えてください（SNS で共有されたときのプレビュー画像に使われます）。

---

## 2. リリースを出す

```bash
git tag v0.1.0
git push origin v0.1.0
```

GitHub Actions の **Release** ワークフローが次を自動で行います。

1. テストを実行
2. Apple シリコン・Intel 両対応でビルド
3. Developer ID で署名し、Apple の公証を受けて、結果をアプリと DMG に添付（staple）
4. GitHub Releases に `MacMerge-0.1.0.dmg` と `MacMerge.dmg`（最新版用の固定名）を公開

### 手元の Mac でリリースを作る場合

```bash
xcrun notarytool store-credentials macmerge-notary   # 最初に一度だけ（Apple ID とアプリ用パスワードを入力）
NOTARY_PROFILE=macmerge-notary VERSION=0.1.0 ./scripts/release.sh
```

署名や公証なしで DMG の作り方だけ確かめるときは `SKIP_NOTARIZE=1 ./scripts/release.sh` を使います（配布には使えません）。

---

## 3. あとで追加する予定のもの

- Homebrew：最初のリリースのあと、自分用のリポジトリ（tap）に cask を置く
- 自動アップデート（Sparkle）
