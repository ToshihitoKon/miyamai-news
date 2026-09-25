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

R2 の状態・台本置き場（後述）を使うため、`pipeline.mode` によらず `--help` 以外のほぼすべての
実行（`--clean` 系を含む）に以下の環境変数が必要。
config.yaml には書かない（config.yaml は機密を持たない前提で運用しているため）。

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
bundle exec ruby miyamai_news.rb --digest-only     # ニュース選別・facts抽出のみ生成して停止（digest以上。R2 の状態は書き戻さない）
bundle exec ruby miyamai_news.rb --script-only     # 台本のみ生成して停止（work/ に書き出す。synthesize以上。R2 の状態は書き戻さない）
bundle exec ruby miyamai_news.rb --handoff-only    # 台本一式を R2 の handoff/ に置いて停止（pipeline.mode によらない。CI 向け）
bundle exec ruby miyamai_news.rb --synthesize-only # R2 の台本（無ければ生成して置く）から音声合成・BGM合成まで（dist/ に書き出して終了。synthesize以上）
bundle exec ruby miyamai_news.rb --publish-only    # dist/ の該当回を公開のみ（publish のみ）
bundle exec ruby miyamai_news.rb --ui-only         # 新しい回を公開せず index.html / manifest.json だけ再生成

# cleaner
bundle exec ruby miyamai_news.rb --clean         # work/ を掃除し（未完了の実行の作業コピーも破棄）、公開済みまたは保持期間を過ぎた dist/ 成果物を削除
bundle exec ruby miyamai_news.rb --clean-archive # archived/ 配下の退避済み成果物を完全削除

# 非対話実行（CI 向け）
bundle exec ruby miyamai_news.rb --ci            # スピナーを出さず進捗を1行ずつ出す

# オプション一覧を表示
bundle exec ruby miyamai_news.rb --help
```

## Tips

### R2 を経由した台本の受け渡し

台本の生成（収集〜TTS 整形）と音声合成は、同じ端末で続けて実行する場合も含めて、必ず
R2 の `handoff/<date_tag>_<slot>/` を経由する。フラグなしで実行すると次の順に進む。

1. R2 に現在の回（`--date`/`--slot` で指定も可）の台本一式があれば、それを使って 4 へ進む
2. 無ければ、公開台帳（`archives.csv`）に既にこの回があれば中断する
3. 台本を生成し、収集windowを確定して内部状態を R2 へ書き戻してから、台本一式を R2 に置く
   （`--handoff-only` はここで停止する）
4. R2 から台本一式を取得して音声合成・BGM 合成（`synthesize` まではここで停止する）
5. publish し、台本一式を `handoff_done/` へ移す

現在の回以外に未公開の台本一式が R2 に残っていれば、1 の時点で警告が出る。`--date`/`--slot` で
その回を指定して実行すれば、残っている台本から合成・publish できる。

リモート（CI 等）で `TZ=Asia/Tokyo` を付けて `--handoff-only --ci` を回して
おけば、手元の実行は 1 で R2 の台本を見つけ、生成を飛ばして音声合成から始まる。
「現在の回」は JST で決めるので、`--date`/`--slot` を省略した実行はタイムゾーンが
JST でなければ中断する。

### パイプラインの内部状態（R2 の state/）

`last_fetch.json`・`feed_cache/`・`used_news_history/` など、実行をまたいで
保持するパイプラインの内部状態は `work/state/` にまとめ、R2 の `state/` と同じ構成で同期する。
正は R2 側で、台本を生成する実行は開始時に `work/state/` へ取り出し、台本を R2 に置く前に書き戻す。途中で失敗した実行の作業コピーは `work/` に残り、R2 がその後更新されていなければ
次の実行がそのまま引き継ぐ。別の実行が先に R2 を更新していた場合は衝突として中断するので、
`--clean` で手元の作業コピーを破棄してから実行し直す。

初回だけ、手元の状態を R2 に置く（`work/` 直下にある旧配置の状態は `work/state/` へ移してから置く）。

```sh
bundle exec ruby scripts/seed_remote_state.rb                              # 計画のみ
envchain cloudflare bundle exec ruby scripts/seed_remote_state.rb --apply  # R2 に状態が無いときだけ置く
```

### 収集window（last_fetch）の確定フロー

収集windowは、台本一式を R2 に置く直前に、その回（`<date_tag>_<slot>`）の確定として進む
（音声合成・publish を待たない）。`last_fetch.json` には直近3回分の確定（回と収集時刻）を残し、
次の回は直前の確定の収集時刻から収集する。`--digest-only`/`--script-only` は状態を
R2 へ書き戻さないので、収集windowは進まない。

確定済みの回を作り直す場合（台本の受け渡しが揃わなかった等）は、1つ前の確定の収集時刻から
収集し直し、紹介済み履歴からその回自身を除いて選定する。作り直せるのは最新の確定の回だけ。

### フィードキャッシュ

各フィードの取得結果は `work/state/feed_cache/<hash>.json` に URL ごと1ファイルで保持する。
同じフィードを最後に取得してから `collect.fetch_skip_minutes` 以内に再実行した場合はキャッシュから結果を返す。`0` にするとスキップを無効化する。

#### deprecated: `work/state/feed_cache.json`

旧・単一ファイル形式のキャッシュ `work/state/feed_cache.json` は、URL 別形式への移行後も
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
