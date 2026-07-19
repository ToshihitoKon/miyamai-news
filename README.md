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
ruby miyamai_news.rb --confirm-fetch    # 前回実行分の収集windowを確定する（成果物確認後に使う）
ruby miyamai_news.rb --auto-confirm     # 前回分を確認せず自動確定してから実行（CI向け）
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

### 収集window（last_fetch）の確定フロー

`digest`/`script`/`synthesize` 相当の実行で新規にRSS収集が発生しても、収集windowは
実行完了と同時には確定しない（`work/last_fetch.json` の `pending_at` に留まる）。
生成し直し（同じ収集windowでの再実行・台本の手直し）が起こり得るため、実行が
完了しただけでは「この収集windowはもう使い終えた」と確定できない。既存の
`news_<date>_<slot>.txt` を再利用しただけで新規収集が起きなかった実行では、
pending化も起きない。

次回実行の開始時、前回の `pending_at` が残っていれば

```
前回の収集windowが未確認です（<時刻>）。確定しますか？確定しなければロールバックします。 [y/N]:
```

と確認される。`y` で確定、`N`（既定・Enter）でロールバックする（収集windowは前回
確定済みの時点のまま変わらない＝取りこぼしを避ける安全側の既定）。

成果物（facts/台本/mp3）を確認できたタイミングで、次回実行を待たずに即座に確定
させたい場合は `--confirm-fetch` を使う。CI等の非対話実行では `--auto-confirm` を
付けて実行すると、確認なしで前回分を自動確定してから続行する。

`--publish-only`・pipeline.mode到達がpublishまで進む実行は、「公開する」こと自体が
確定行為と一体なので、pendingを経由せず即座に確定する（対話なし、従来通り）。

### フィードキャッシュ

各フィードの取得結果は `work/feed_cache/<hash>.json` に URL ごと1ファイルで保持する
（記事の初登場時刻 seen_at の履歴。`--clean` の対象外で回をまたいで残る）。同じフィードを
最後に取得してから `config.yaml` の `collect.fetch_skip_minutes`（既定5分）以内に再実行
した場合は、HTTP を叩かずキャッシュから前回と同じ結果を返す。短時間の再実行で全フィードを
取り直さずに済み、一部フィードが一時的に落ちていても先へ進める。`0` にするとスキップを無効化
して毎回必ず取得する。

旧・単一ファイル形式のキャッシュ `work/feed_cache.json` は、URL 別形式への移行後も
seen_at の継承元として残している（消すと移行直後に過去記事が新着扱いになり二重紹介が
起きる）。安全に削除できるようになったかは次で確認する（判定のみ。削除はしない）:

```sh
ruby scripts/check_legacy_feed_cache.rb
```

`Safe to delete` と出たら `rm work/feed_cache.json` してよい。

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

`--date` / `--slot` を省略すると実行時刻から自動で決まる。1日を 5:00 起点で 6 時間
ずつ 4 分割し、時間帯 `slot` は morning=5〜11時 / afternoon=11〜17時 / evening=17〜
23時 / midnight=23〜翌5時。midnight は日付をまたぐため、0〜5時に実行した回は前日の
深夜（前日 midnight）の番組として扱う（日付が 1 日戻る）。
1日に複数回まわしてもファイル名が衝突せず、別エピソードとして共存する。
