# 宮舞モカの技術ニュース パイプライン

技術ニュースを RSS で収集し、AI によるカテゴリ別選別・要約（digest）→ 台本執筆・音声合成
（VOICEPEAK 宮舞モカ）・BGM 合成（synthesize）→ GCS 上のペライチ再生ページと Atom フィードの
更新（publish）まで、`pipeline.mode` で指定した段階まで進む。GCS への公開が前提ではなく、
ローカルで完結するニュース要約ツールとしても、音声ファイル生成までのツールとしても使える。

プロンプトとページ / フィードのマークアップはすべて `templates/` に外出ししてあり、
文面やデザインの調整は Ruby に触れず `templates/` 内で完結する。

## Prerequisites

- Ruby（`.tool-versions` 参照）。gem は `bundler/inline` で自動取得
- Claude Code CLI 等の AI CLI（`config.yaml` の `ai_agent` で設定。すべての mode で必須）

`pipeline.mode: synthesize` 以上を使う場合は追加で:

- [VOICEPEAK](https://www.ah-soft.com/voice/moca/)（宮舞モカ）
- `ffmpeg`（BGM 合成）

`pipeline.mode: publish` を使う場合は追加で:

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

### 0. どこまで使うか（pipeline.mode）

`config.yaml` の `pipeline.mode` で、パイプラインをどこまで実行するかの上限を決める。
**未指定時は `digest`**。既存のフルパイプライン運用を続ける場合は `publish` を明示すること。

| mode | 到達点 | 追加で必要なもの |
|---|---|---|
| `digest`（既定） | RSS収集 → AIによるカテゴリ別選別 → facts抽出（ニュース要約） | AI CLI のみ |
| `synthesize` | 上記 → 台本執筆 → 音声合成 → BGM合成（`dist/` に mp3 を書き出す） | + VOICEPEAK, ffmpeg |
| `publish` | 上記 → GCS への publish（フルパイプライン） | + gcloud, GCS バケット |

```yaml
pipeline:
  mode: publish  # digest（既定）/ synthesize / publish
```

必須の config セクションは mode によって変わり、起動時に一括検証される（不足していれば
実行前にまとめてエラーになる）。`digest` だけを使うなら `gcs`/`voicepeak`/`mixer`/`assets`
セクションは不要。

### 1. 設定ファイル

環境依存する値（VOICEPEAK のパス、BGM・カバー画像、GCS バケット名など）は
すべて `config.yaml` に集約している。サンプルからコピーして値を埋める。

```sh
cp config.sample.yaml config.yaml
# エディタで config.yaml を開き、環境に合わせて書き換える
```

`config.yaml` は git 管理外。各項目の意味は `config.sample.yaml` のコメントを参照。

### 2. 素材の用意（synthesize 以上を使う場合）

BGM・カバー画像・アイコンはリポジトリに含めていない。各自で用意し、`config.yaml` の
`assets.bgm_path` / `assets.cover_image` / `assets.icon_image` にパスを設定する。

- **BGM**: 任意の音源。既定では猫きまぐれBGM工房様の「古びた魔法書」を利用（<https://kim4gure.com/>）
- **カバー画像**: 横長バナー。Slack のリンクプレビューと再生ページで使う。
  事前に `gs://<bucket>/<cover_image>` へ手動アップロードしておく
- **アイコン**: PWA（ホーム画面に追加）用の正方形画像。512x512 以上を推奨。
  事前に `gs://<bucket>/<icon_image>` へ手動アップロードしておく

  ```sh
  gcloud storage cp miyamai_news.webp      gs://<bucket>/miyamai_news.webp
  gcloud storage cp miyamai_news_icon.png  gs://<bucket>/miyamai_news_icon.png
  ```

  `manifest.json` は公開時に自動生成・アップロードされるが、参照先の
  アイコン画像は上記のとおり手動で置く必要がある（未アップロードだと 404 になる）。

## Usage

`pipeline.mode` がフラグの実行できる上限を決める。フラグなし実行はその上限まで自動的に
進み、`--digest-only` は `digest` 以上、`--script-only`/`--synthesize-only` は
`synthesize` 以上、`--publish-only` は `publish` を要求する（不足する mode で
実行しようとするとエラーになる）。

```sh
ruby miyamai_news.rb                    # pipeline.mode の上限まで自動的に進む
ruby miyamai_news.rb --digest-only      # ニュース選別・facts抽出のみ生成して停止（digest以上）
ruby miyamai_news.rb --script-only      # 台本のみ生成して停止（work/ に書き出す。synthesize以上）
ruby miyamai_news.rb --synthesize-only  # 音声合成・BGM合成のみ（dist/ に書き出して終了。synthesize以上）
ruby miyamai_news.rb --publish-only     # dist/ の該当回を公開のみ（publish のみ）
ruby miyamai_news.rb --clean            # work/ を掃除し、公開済みの dist/ 成果物を削除
ruby miyamai_news.rb --clean-archive    # archived/ 配下の退避済み成果物を完全削除
ruby miyamai_news.rb --ui-only          # 新しい回を公開せず index.html / manifest.json だけ再生成
ruby miyamai_news.rb --help             # オプション一覧を表示
```

`--ui-only` は既存 `archives.csv` を読み込んで再生成するだけで、mp3・used.txt・transcript.txt・
archives.csv・feed.xml には触れない。Atom の `<updated>` も動かないため購読者への「新着」通知は
発生しない。UI 文言修正だけを即時反映したいときに使う。

publish のたびに `config.yaml` の `gcs.retention_episodes` を超えた古い回は
`archives.csv`/`feed.xml`/`index.html` の一覧から外され、GCS 上の実ファイル
（mp3・used.txt・transcript.txt）は削除されず `archived/` プレフィックス配下へ
退避される。`archived/` に溜まったファイルを完全に削除したい場合は
`--clean-archive` を実行する。

`--script-only` は台本を確認・手直ししてから音声を作りたいときに使う。生成された
台本（`work/script_<date>_<slot>.txt`）を確認し、必要なら手直ししたうえで、フラグ
なしで再実行すると既存の台本を再利用して、VOICEPEAK 向けの整形〜音声合成〜公開まで
続きから進む。

対象の回を明示する場合:

```sh
# --publish-only で過去回を公開し直す
ruby miyamai_news.rb --publish-only --date 2026-07-10 --slot morning
```

台本生成・整形に使う AI CLI は `config.yaml` の `ai_agent` で設定する（`bin`/`model` 系の値をツールに合わせて書き換える。既定は Claude Code CLI）。

`pipeline.mode: digest`（既定）のフラグなし実行、および `--digest-only` は、
RSS収集・AI選別・facts抽出（ニュース要約、`work/news_facts_<date>_<slot>.txt`）
までで停止する。VOICEPEAK・ffmpeg・GCS には一切触れないため、ニュースの要約だけを
手元で確認したい用途に使える。`--digest-only` は `pipeline.mode` が `synthesize`/
`publish` のときでも digest の到達点だけを明示的に呼びたい場合に使う。

`--date` / `--slot` を省略すると実行時刻から自動で決まる。1日を 3:00 起点で 8 時間
ずつ 3 分割し、時間帯 `slot` は morning=3〜11時 / afternoon=11〜19時 / evening=19〜
翌3時。evening は日付をまたぐため、0〜3時に実行した回は前日の夜（前日 evening）の
番組として扱う（日付が 1 日戻る）。
1日に複数回まわしてもファイル名が衝突せず、別エピソードとして共存する。
