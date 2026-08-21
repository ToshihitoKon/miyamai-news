# 宮舞モカの技術ニュース パイプライン

RSS feed から最新のニュースを AI で要約し、宮舞モカによる読み上げニュース番組を生成する。

- 技術ニュースを RSS で収集
- AI によるカテゴリ別選別・要約
- 台本執筆
- 音声合成
- BGM 合成
- Google Cloud Storage の再生ページへアップロード、Atom フィードの更新

以下の3パターンの利用方法を想定している。

- ニュースの要約のみ (mode:digest)
- ニュースの合成音声の生成 (mode:synthesize)
- 音声ニュースを公開 (mode:publish)

## Prerequisites

- Ruby
- AI Agent CLI (Claude Code or Antigravity)

Antigravity を使う場合に追加で必要

- Node.js 18 以降（ニュース抽出処理が `npx` 経由で MCP サーバーを起動するため）

mode:synthesize, publish の場合に追加で必要

- ffmpeg
- [VOICEPEAK 宮舞モカ](https://www.ah-soft.com/voice/moca/)

mode:publish の場合に追加で必要

- [wrangler](https://developers.cloudflare.com/workers/wrangler/) v4 以降
- Cloudflare アカウント（Workers + R2）

## Setup

```bash
bundle install
cp config.sample.yaml config.yaml
```

publish には以下の環境変数が必要。config.yaml には書かない（config.yaml は機密を
持たない前提で運用しているため）。

| 環境変数 | 用途 |
| --- | --- |
| `R2_ACCESS_KEY_ID` | R2 の S3 互換 API |
| `R2_SECRET_ACCESS_KEY` | 同上 |

R2 のトークンは Cloudflare ダッシュボードの R2 > API トークンから発行する
（`Object Read & Write` が最小権限）。Secret Access Key はトークン値の SHA-256
ハッシュで、発行直後しか表示されない。

[envchain](https://github.com/sorah/envchain) に入れておくと、シェルに export した
まま放置せずに済む。

```bash
envchain --set cloudflare R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
envchain cloudflare bundle exec ruby miyamai_news.rb
```

`wrangler deploy` の認証は `wrangler login`（対話ログイン）で済ませる場合は環境変数
不要。CI 等から流す場合のみ `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` を渡す。

`assets.cover_image` / `assets.icon_image` は R2 の `assets/` プレフィックスへ
アップロードしておく。版権素材をリポジトリに置かずに済ませるためで、publish 時に
手元へ実体がある必要はない。

```sh
envchain cloudflare bundle exec ruby scripts/upload_assets.rb --file miyamai_news.webp --file miyamai_news_icon.png
```

カスタムドメインは `wrangler.jsonc` の `routes` に `custom_domain: true` で宣言すると
`wrangler deploy` 時に DNS レコードと証明書が自動発行される。ただし**対象ホスト名に
既存の CNAME レコードがあると失敗する**ので、先に削除しておく。

### Web Push 通知（任意機能）

`config.yaml` に `web_push` セクションを設定すると、publish 時に購読者へブラウザ
通知を送る機能が有効になる。未設定なら完全に無効化される。

Worker 側の依存関係は Node.js（npm）が必要。

```bash
npm install
```

D1 データベースと VAPID 鍵を、Worker コードのデプロイより先に用意する。

```bash
wrangler d1 create miyamai-news-subscriptions
# 出力された database_id を wrangler.jsonc の d1_databases[0].database_id に反映する

wrangler d1 migrations apply miyamai-news-subscriptions --remote

npx web-push generate-vapid-keys
# 出力された Public Key を config.yaml の web_push.vapid_public_key に設定する
```

Worker 側の secret（`wrangler secret put <name>` で設定、config.yaml には書かない）。

| secret | 用途 |
| --- | --- |
| `VAPID_PUBLIC_KEY` | 上記で生成した Public Key |
| `VAPID_PRIVATE_KEY` | 上記で生成した Private Key |
| `VAPID_SUBJECT` | `mailto:` アドレスまたは `https:` URL |
| `NOTIFY_SHARED_SECRET` | `/notify` の HMAC 認証に使う共有シークレット（任意の乱数文字列） |

miyamai-news 側（`Internal::EpisodeNotifier`）にも同じ共有シークレットを渡す。

| 環境変数 | 用途 |
| --- | --- |
| `WEB_PUSH_NOTIFY_SECRET` | `NOTIFY_SHARED_SECRET` と同じ値 |

Worker 側のテストは Vitest（`@cloudflare/vitest-pool-workers`）で実行する。

```bash
npx vitest run
```

synthesize には BGM 素材を用意し `assets.bgm_path` にパスをセットする必要がある。index.html.erb に記載している BGM は[猫きまぐれBGM工房](https://kim4gure.com/) 様「古びた魔法書」

## Usage

```sh
bundle exec ruby miyamai_news.rb # pipeline.mode の上限まで自動的に進む 

# 特定のフェーズのみを実行する
bundle exec ruby miyamai_news.rb --digest-only     # ニュース選別・facts抽出のみ生成して停止（digest以上）
bundle exec ruby miyamai_news.rb --script-only     # 台本のみ生成して停止（work/ に書き出す。synthesize以上）
bundle exec ruby miyamai_news.rb --synthesize-only # 音声合成・BGM合成のみ（dist/ に書き出して終了。synthesize以上）
bundle exec ruby miyamai_news.rb --publish-only    # dist/ の該当回を公開のみ（publish のみ）
bundle exec ruby miyamai_news.rb --ui-only         # 新しい回を公開せず index.html / manifest.json だけ再生成

# cleaner
bundle exec ruby miyamai_news.rb --clean         # work/ を掃除し、公開済みの dist/ 成果物を削除
bundle exec ruby miyamai_news.rb --clean-archive # archived/ 配下の退避済み成果物を完全削除

# last_fetched_at (RSS Feed 最終 fetch 時刻）の管理
bundle exec ruby miyamai_news.rb --confirm-fetch # 前回実行分の収集windowを確定する（成果物確認後に使う）
bundle exec ruby miyamai_news.rb --restore-fetch # 誤ってロールバックした収集windowを復元する
bundle exec ruby miyamai_news.rb --auto-confirm  # 前回分を確認せず自動確定してから実行（CI向け）

# オプション一覧を表示
bundle exec ruby miyamai_news.rb --help
```

## Tips

### 収集window（last_fetch）の確定フロー

`digest`/`script`/`synthesize` 相当の実行で新規にRSS収集が発生しても、収集windowは実行完了と
同時には確定せず `work/last_fetch.json` の `pending_at` に留まる（同じ収集windowでの再実行・台本の
手直しが起こり得るため）。既存の `news_<date>_<slot>.txt` を再利用しただけの実行では pending 化も起きない。

次回実行の開始時、前回の `pending_at` が残っていればダイアログで confirm か rollback かを選択する。

成果物（facts/台本/mp3）を確認できたタイミングで、次回実行を待たずに即座に確定
させたい場合は `--confirm-fetch` を使う。CI等の非対話実行では `--auto-confirm` を
付けて実行すると、確認なしで前回分を自動確定してから続行する。

publish は pending を経由せずに確定する。

### フィードキャッシュ

各フィードの取得結果は `work/feed_cache/<hash>.json` に URL ごと1ファイルで保持する。
同じフィードを最後に取得してから `collect.fetch_skip_minutes` 以内に再実行した場合はキャッシュから結果を返す。`0` にするとスキップを無効化する。

#### deprecated: `work/feed_cache.json`

旧・単一ファイル形式のキャッシュ `work/feed_cache.json` は、URL 別形式への移行後も
seen_at の継承元として残している。
安全に削除できるかどうかのチェックスクリプトを同梱している。

```sh
bundle exec ruby scripts/check_legacy_feed_cache.rb
```

### 日付と slot

Slot は時間帯を示す単位で、1日を 5:00 起点で 6 時間ずつ 4 分割したもの。

- morning: 5〜11時
- afternoon: 11〜17時
- evening: 17〜23時
- midnight: 23〜翌5時

midnight は日付をまたぐため、0〜5時に実行した回は前日の深夜（前日 midnight）の番組として扱う。
1日に複数回まわしてもファイル名が衝突せず、別エピソードとして共存する。

### (publish) 過去記事の自動アーカイブについて

publish のたびに `cloudflare.retention_episodes` を超えた古い回は一覧から外れ、R2 上の実ファイルは
削除されず `archived/` プレフィックス配下へ退避される（配信対象の `episodes/` の外なので、
退避した時点で公開経路からは読めなくなる）。
`--clean-archive` を実行することで、`archived/` 以下のファイルを削除できる。
