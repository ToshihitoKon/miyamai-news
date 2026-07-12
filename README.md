# 宮舞モカの技術ニュース パイプライン

技術ニュースを RSS で収集し、台本生成 → 音声合成（VOICEPEAK 宮舞モカ）→ BGM 合成まで一貫して行い、
GCS 上のペライチ再生ページと Atom フィードを更新する。

プロンプトとページ / フィードのマークアップはすべて `templates/` に外出ししてあり、
文面やデザインの調整は Ruby に触れず `templates/` 内で完結する。

## Prerequisites

- Ruby（`.tool-versions` 参照）。gem は `bundler/inline` で自動取得
- [VOICEPEAK](https://www.ah-soft.com/voice/moca/)（宮舞モカ）
- `ffmpeg`（BGM 合成）
- `gcloud`（認証・プロジェクト設定済み）
- 公開読み取り可能な GCS バケット

### GCS バケットの公開設定

再生ページ・フィード・mp3 は誰でも閲覧できる必要がある。バケットに `allUsers` の
「Storage オブジェクト閲覧者」ロールを付与し、公開バケットにする。

```sh
gcloud storage buckets add-iam-policy-binding gs://<bucket> \
  --member=allUsers --role=roles/storage.objectViewer
```

## Setup

### 1. 設定ファイル

環境依存する値（VOICEPEAK のパス、BGM・カバー画像、GCS バケット名など）は
すべて `config.yaml` に集約している。サンプルからコピーして値を埋める。

```sh
cp config.sample.yaml config.yaml
# エディタで config.yaml を開き、環境に合わせて書き換える
```

`config.yaml` は git 管理外。各項目の意味は `config.sample.yaml` のコメントを参照。

### 2. 素材の用意

BGM・カバー画像・アイコンはリポジトリに含めていない。各自で用意し、`config.yaml` の
`assets.bgm_path` / `assets.cover_image` / `assets.icon_image` にパスを設定する。

- **BGM**: 任意の音源。既定では猫きまぐれBGM工房様の「古びた魔法書」を利用（<https://kim4gure.com/>）
- **カバー画像**: 横長バナー。Slack のリンクプレビューと再生ページで使う。
  事前に `gs://<bucket>/<cover_image>` へ手動アップロードしておく
- **アイコン**: PWA（ホーム画面に追加）用の正方形画像。512x512 以上を推奨。
  事前に `gs://<bucket>/<icon_image>` へ手動アップロードしておく

  ```sh
  gcloud storage cp miyamai_news.png       gs://<bucket>/miyamai_news.png
  gcloud storage cp miyamai_news_icon.png  gs://<bucket>/miyamai_news_icon.png
  ```

  `manifest.json` は公開時に自動生成・アップロードされるが、参照先の
  アイコン画像は上記のとおり手動で置く必要がある（未アップロードだと 404 になる）。

## Usage

```sh
ruby miyamai_news.rb                  # 生成→公開まで一気通し
ruby miyamai_news.rb --script-only    # 台本のみ生成して停止（work/ に書き出す）
ruby miyamai_news.rb --generate-only  # 生成のみ（dist/ に書き出して終了）
ruby miyamai_news.rb --publish-only   # dist/ の該当回を公開のみ
ruby miyamai_news.rb --clean          # work/ を掃除し、公開済みの dist/ 成果物を削除
```

`--script-only` は台本を確認・手直ししてから音声を作りたいときに使う。生成された
台本（`work/script_<date>_<slot>.txt`）を確認し、必要なら手直ししたうえで、フラグ
なしで再実行すると既存の台本を再利用して、VOICEPEAK 向けの整形〜音声合成〜公開まで
続きから進む。

対象の回や BGM、生成に使う AI CLI ツールを明示する場合:

```sh
# --publish-only で過去回を公開し直す
ruby miyamai_news.rb --publish-only --date 2026-07-10 --slot morning
# BGM を一時的に差し替える
ruby miyamai_news.rb --bgm path/to/bgm.mp3
# 生成に Antigravity CLI (agy) を使用する（--cli antigravity や --agy も可）
ruby miyamai_news.rb --antigravity
# 生成に Claude Code CLI を使用する
ruby miyamai_news.rb --claude
```

`config.yaml` の `ai.cli` に `claude` または `antigravity` を設定することで既定の AI CLI を選択できます。コマンドライン引数（`--antigravity` や `--claude`）を渡すと、設定ファイルの既定値をその実行のみ上書きできます。

`--date` / `--slot` を省略すると実行時刻から自動で決まる。1日を 3:00 起点で 8 時間
ずつ 3 分割し、時間帯 `slot` は morning=3〜11時 / afternoon=11〜19時 / evening=19〜
翌3時。evening は日付をまたぐため、0〜3時に実行した回は前日の夜（前日 evening）の
番組として扱う（日付が 1 日戻る）。
1日に複数回まわしてもファイル名が衝突せず、別エピソードとして共存する。
