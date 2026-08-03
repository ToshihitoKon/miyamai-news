# パイプラインのドメイン知識・実装上の前提

本番安全性の原則（CLAUDE.md 参照）とは別に、実装が前提としている業務ルール・外部ツールの癖・
ファイル間の不変条件をここにまとめる。コードコメントの整理に伴い、複数ファイル・
複数箇所に分散していた説明をここに集約した。コードを変更する際は、該当項目が
まだ成り立っているか確認すること。

コード側にはこのファイルへの参照コメントも含め、WHY・背景説明のコメントは一切書かない
（詳細は CLAUDE.md「コメントの整理方針」節参照）。ある挙動の「なぜ」を説明したくなったら、
まずこのファイルに該当項目があるか確認し、無ければここに追記する。

### FeedCache（フィード収集・重複判定）

- 新着判定は掲載日時ではなく seen_at（このキャッシュが entry を初めて見た時刻）を使う。
  はてなブックマーク・Qiita のようなキュレーション系フィードは、昔書かれた記事が
  今になって話題化して再度載ることがあるため。
- パージ（キャッシュからの削除）は last_fetched_at（直近でそのフィードに実際に
  見えていたか）基準で行う。seen_at 基準にすると、OpenAI Blog のように過去記事を
  フィードに載せ続けるソースで、記事がキャッシュから消えた後に「未知の entry」として
  再登場し二重紹介につながる。
- キャッシュはフィード URL ごとに 1 ファイル（`work/feed_cache/<正規化 link の SHA1>.json`）。
  1 回の HTTP GET で返るフィードがキャッシュの単位で、GET パラメータ違いは別レスポンス
  なので別ファイルにする。config の rss_feed_sources は 1 要素 = 1 URL = 1 キャッシュ
  ファイル。同じ記事が複数フィードから流れてくる重複は FeedCache の関心事ではなく、
  収集後の dedup_by_title（タイトル基準）が扱う。
- 新規 entry の seen_at 初期値は、旧・単一ファイル形式のキャッシュ（`work/feed_cache.json`、
  legacy_path で渡す link=>seen_at の台帳）にその link があればその値を継承し、無ければ
  now を使う。URL 別ファイルへ分割した際、まだ一度も fetch していないフィードの entry を
  一律 now にすると、旧来から知っていた記事が一斉に新着扱いになり大量に二重紹介される
  のを防ぐため。旧台帳は書き換えず、`scripts/check_legacy_feed_cache.rb` の判定で安全に
  なったら手で削除する（max(seen_at) < now - retention_days）。
- 収集 window の since は排他的下限（seen_at > since）で判定する。同一実行由来の
  confirmed_at と seen_at が一致することがあり、含めると同じ記事を毎回新着として
  二重紹介してしまう。
- `select_since_for` は対象 entry を `link` で `uniq` してから返す。1 回のフィード
  取得内で同じ link が複数回出現しても（フィード側の重複掲載等）、selector への
  候補としては 1 件にまとめる。
- extra フィールド（はてブのブックマーク数など）は、書き込み時はシンボルキーだが
  JSON 往復後は常に文字列キーになる。extra を読む側（hatena_bookmarks.rb 等）は
  文字列キー前提で書くこと。
- 最終 fetch から `collect.fetch_skip_minutes`（既定5分）以内は HTTP を叩かず、前回
  キャッシュから同じ結果を返す（スキップ時は seen_at / last_fetched_at / fetched_at を
  一切更新しない完全な read no-op。fetched_at を更新すると skip_window ごとの再実行で
  永久にスキップし続けてしまう）。スキップは HTTP を叩かない＝FetchError も起きないので、
  一部フィードが一時的に落ちていても短時間の再実行なら先へ進める。0 で無効。
  スキップ時に擬似 entries として渡す link 集合（`cached_entries`）は、
  `entries.keys` 全件ではなく「`last_fetched_at` が直前の実 fetch の `fetched_at` と
  一致する entry」だけに絞る。purge（前掲パージの項参照）は実 fetch 時にしか走らない
  ため、`entries.keys` にはフィードから既に落ちた記事が最大 retention_days 日分残り
  得る。これをそのままスキップ経路に使うと、実 fetch では候補に出ない古い記事が
  数分後の再実行（スキップ経路）でだけ候補に復活してしまい、「前回 fetch と同じ結果を
  返す」というスキップの契約が崩れる。`record_seen` は実 fetch のたびに今回フィードに
  載っていた全 entry の `last_fetched_at` をその回の `now`（= `fetched_at` と同じ値）で
  更新するため、両者の一致だけで「直前の実 fetch で実際に登場した link」を機械的に
  判別できる。
- FeedCache#fetch は複数スレッドから同時に呼んでよい。フィードごとに別ファイルなので
  キャッシュ更新の直列化（Mutex）は不要（同一 URL を 2 スレッドが同時に触らない前提。
  ScriptGenerator が 1 フィード 1 ジョブで並列に呼ぶ）。書き込みは tmp→rename で atomic
  にし、書き込み途中でクラッシュしても壊れたファイルを残さないようにする。
- entry の同一性キーは正規化した link（末尾スラッシュの有無を無視）。キャッシュファイル名
  も正規化した URL の SHA1 で、いずれも feed_parser.rb#normalize_link を通す。正規化前の
  URL をそのまま identity にすると同じ記事を別記事として扱ってしまう。
- `load_cache` は、キャッシュファイルが valid JSON だが Hash でない壊れ方をしていた場合、
  空扱いにフォールバックせず abort する。空扱いにすると、そのフィードの全 entry が
  「初登場」＝新着として再流入し、二重紹介を招くため。
- `parse`（フィード本文のパース）が失敗した場合は即 `FetchError` にする。HTTP 自体は
  成功しているのに本文が壊れているケースで、リトライしても直らないため中断へ回す。
- `@legacy_seen_at`（旧台帳からの seen_at 継承元）は `initialize` で一度だけ読み込む。
  並列 fetch の途中で読み直すと、スレッドごとに参照する内容がぶれるため。
- `purge_expired` で `last_fetched_at`/`seen_at` の時刻パースに失敗した entry は、
  保持し続ける意味がないので削除対象にする。
- `meta_extra` が読む旧トップレベルの `"bookmarks"` キーは、extra フィールド導入前の
  旧キャッシュ形式との後方互換のためのフォールバック。新形式は `"extra"` キーに
  まとまっている。
- 旧・単一ファイル形式のキャッシュ（`work/feed_cache.json`）を削除してよいかどうかは
  `scripts/check_legacy_feed_cache.rb` が判定する（削除自体は行わず、安全側に倒して
  人間が手で行う）。旧台帳は「まだ一度も fetch されていないフィードの seen_at を継承する
  元」として残しており、旧台帳は link 単位のフラット構造でどの link がどのフィード由来か
  分からないため、「あるフィードが一巡した」だけでは消せない。まだ初回 fetch していない
  別フィードが、その初回時に旧台帳を参照する必要が残るからだ。早く消すと初回誤認で
  seen_at が now にリセットされ、旧来から知っていた記事が新着として二重紹介される。
  安全条件は `max(旧台帳の全 entry の seen_at) < now - retention_days`。この時点では、
  旧台帳が継承しうる seen_at はすべて「新方式でもどのみち purge される領域
  （last_fetched_at < now - retention_days）」に入っている。継承しても保持されない情報しか
  残っていないので、消しても失う「生きた継承情報」はゼロ。フィードから既に消えた link
  （新方式でも二度と取得されない）も、この条件下では継承価値がない。

### HatenaBookmarks（はてなブックマーク RSS 固有の知識）

- `rss` gem ははてなブックマーク RSS(RDF) の hatena 名前空間の要素（ブックマーク数等）を
  公開しないため、REXML で直接パースしてブックマーク数を取り出す。
- `count_of(extra)` は `extra` が nil、またはこのモジュールが付与したもの以外
  （はてブ以外のソース由来）であれば 0 を返す。他ソースの entry にブックマーク数
  欄が無いのは異常ではないため、例外にせず黙って 0 扱いにする。

### HttpFetcher（単一 URL の取得）

- `MAX_REDIRECTS` はリダイレクト追従の上限ホップ数。無限リダイレクトループによる
  永久ハングを防ぐための安全弁。
- 取得失敗時に指数バックオフでリトライするのは、一時的に 502 等のエラーを返す
  サーバーがあるため。
- リダイレクト先の `Location` ヘッダーは相対 URI のことがある（RFC 7231 で許容されており
  実サーバーでも一般的）ため、直前の URL を基点に `URI#merge` で解決する。

### TemplateRenderer（ERB テンプレート描画）

- `render` は渡された context オブジェクトの binding で ERB を評価する。テンプレート
  側から context のインスタンス変数（`@title` 等）や private メソッド（`h`,
  `date_with_slot` 等）をそのまま呼べるのはこのため。テンプレート固有の値は
  この暗黙のスコープ共有とは別に、`locals` ハッシュで明示的に渡す。
- コンパイル済み ERB をテンプレート名でキャッシュする。同一プロセス内で同じ
  テンプレートを何度も描画しても、ファイル読み込みと構文解析は 1 回で済む。
- `trim_mode: "-"` は `<%- -%>` を書いたときだけ前後の空白を削る設定。通常の `<%= %>`
  には影響しないため、プロンプト用テンプレートと HTML/XML テンプレートを同じ設定で
  扱える。

### CommandError（外部コマンドのエラーメッセージ整形）

- `tail` が単純な `err[-max_chars..]` ではなく長さチェックを挟んでいるのは、Ruby が
  文字列長より大きい負インデックスの範囲アクセスで `nil` を返す仕様があるため
  （例: `"short"[-300..] #=> nil`）。300 文字未満の stderr（一行エラー等）でこれを
  踏むと、失敗理由が丸ごと消えてしまう。

### AudioMixer（BGM 合成）

- `voice_boost_db` は VOICEPEAK の出力音量が小さめなため底上げするゲイン。未指定時は
  0（無調整）。
- `run_mix` の ffmpeg フィルタで `-stream_loop -1` を指定するのは、BGM がナレーションより
  短くても最後まで途切れないようループさせるため。`amix` に `normalize=0` を渡すのは、
  自動音量正規化を無効化し、指定した音量バランス（bgm_volume/voice_boost_db）をそのまま
  保つため。
- `probe_duration` が `out.strip.to_f` ではなく `Float()` で厳格パースしているのは、
  ffprobe が成功終了（exit 0）でも duration を取得できない場合に `N/A` を出力する
  ことがあるため（Issue #90）。`"N/A".to_f` は例外を出さず黙って `0.0` になり、
  その後段のループ回数計算等に誤った値が伝播してしまう。

### Slot（番組の時間帯区分）

- 1 日に複数回番組をまわしても回ごとに別の slot を持たせ、ファイル名を衝突させず
  別エピソードとして共存させるための区分。
- `sort_key` は未知の slot を例外にする。サイレントに扱うと、ソート順が壊れたまま
  気づかずに進行してしまうため、早期に気づけるようにしている。
- `FILENAME_PATTERN` は `JA_LABELS` のキーから組み立てる。決め打ちの正規表現にすると、
  対応する slot が増減したときに追従漏れが起きるため。

### VoiceSynthesizer / VOICEPEAK（外部 GUI アプリの癖）

- VOICEPEAK は本来 GUI アプリで、間髪入れず連続起動すると初期化中にクラッシュする
  ことがある。各合成後に interval_sec だけ間隔を空けて安定させる。
- 初期化タイミングでまれにクラッシュする。失敗時は指数バックオフでリトライする
  （max_retries / retry_base_sec）。
- 異常終了後もプロセスが応答を返さず永久にハングすることがある。timeout_sec を
  超えたらハングとみなし、プロセスグループごと TERM→KILL の順で kill する。
- **実際のバグ要因（重要）**: 子プロセスの stdout/stderr は `Process#join` の前に
  別スレッドで読み進めておくこと。読まずに join を待つと、出力が OS のパイプ
  バッファ（約 64KB）を超えた時点で子プロセスの write がブロックし、実際には
  正常動作中であっても timeout_sec 超過による「偽ハング」と誤判定してしまう。
- VOICEPEAK は空白（全角・半角）を間として認識せず、前後の語をそのまま繋げて
  読み上げる。読点「、」なら実際に間を取って読む。tts_script 側で語の切れ目を
  空白で表現しても無音は入らないため、format.prompt.erb では空白を残さず読点に
  置き換えるか詰めるルールにしている。
- MAX_CHARS=140 は VOICEPEAK の 1 回の合成呼び出しあたりの文字数上限（ハード制約）。
- 話題転換タグ `[interval:mid]` / `[interval:long]` は、文分割・MAX_CHARS 分割より
  **先に**検出・除去すること。後で分割するとタグ文字列自体が分割で壊れる恐れがある。
- `split_chunks` が正規表現 `scan` でテキストとタグの組を切り出す際、末尾に
  `["", nil]`（空文字列＋タグなし）が必ず 1 組余分に付く（`scan` の走査上の
  副産物）。そのままチャンクにすると空の合成呼び出しが発生するため、最後にこの
  組だけを取り除く。
- `voice_{date}_{slot}.mp3` は合成結果のキャッシュとして機能する。存在すれば
  VOICEPEAK を起動せず再利用する（`--synthesize-only` でブースト値だけ調整したい
  場合など）。
- `wav_{date}_{slot}/` ディレクトリが残っている場合、前回の合成が途中でクラッシュ
  した痕跡。完全成功時のみ削除されるので、残っているチャンクを再利用して続きから
  再開できる。
- wav チャンクのファイル名は `<index>_<textのSHA256先頭8桁>.wav`。index だけで
  照合すると、クラッシュ後に `tts_script_*.txt` を編集して再実行した際に
  `split_chunks` の分割境界がずれても旧スクリプト由来の wav をそのまま再利用して
  しまい、編集前後の文が混在・重複・欠落した音声が無警告で生成される。テキストの
  ダイジェストをファイル名に含めることで、内容が変わったチャンクは別ファイル名に
  なり自然に再合成される。
- `Process.getpgid(wait_thr.pid)` は、子プロセスが起動直後にクラッシュして Open3 の
  waiter スレッドに先に回収されると `Errno::ESRCH`（`SystemCallError` のサブクラスで
  `RuntimeError` ではない）を投げる。「VOICEPEAK は初期化タイミングでまれにクラッシュ
  する→指数バックオフでリトライ」という設計意図のケースなので、`RuntimeError` に
  正規化して `synthesize_chunk` の既存リトライ機構に乗せる。
- 無音秒数の設定値が 0 以下の場合、その pause 種類はハッシュのキー自体を持たない
  （0 秒のファイルを作るのではなく、キー省略により `concat_to_mp3` が `Hash#[]`
  の nil で無音挿入をスキップする）。
- 直後に文が続かない話題転換タグ（連続するタグなど）は、その pause 指定ごと
  静かに捨てられる（低頻度の許容済みエッジケース）。

### Publisher / Internal::Site（公開先の運用ルール）

公開されているサイトそのものを `Internal::Site`（`lib/internal/site.rb`）が表す。
`Publisher` は「エピソード資材を置く」「台帳を読み書きする」「サイトを反映する」
という語彙でしかサイトを触らず、**ストレージの種類・キー構成・デプロイ手段・
ベンダー名を一切知らない**。`Site` の下に `Internal::R2Storage`（S3 互換 API の
オブジェクト操作）が入る 3 層構成。

- `Publisher` … 何を公開するか（台本・台帳・ページの内容）
- `Internal::Site` … サイトの状態と操作（キー構成・公開 URL・保持件数・反映）
- `Internal::R2Storage` … オブジェクトストレージの操作

「publish 先」ではなく「サイト」と捉えているのは、この層が書き込み
（publish）だけでなく台帳の読み取り・退避・保持件数といったサイトの
ライフサイクル全体を受け持つため。

`Publisher` が `Config` から直接読むのは `assets`（画像）だけで、公開先の設定は
`Internal::Site.from_config` が `cloudflare` セクションからまとめて読む。
`retention_episodes` は「保持する話数」という公開ポリシーなので、ストレージの
設定ではなく `Site` が持つ。

`--ui-only`（`republish_ui` → `deploy_site`）は `assets` を参照するため、
`miyamai_news.rb` は `cloudflare` に加えて `assets` も起動時に検証する
（`Config.validate_sections!("cloudflare", "assets")`）。`--clean`/`--clean-archive`
は `deploy_site` を呼ばないので `cloudflare` のみで足りる。

`Internal` 名前空間の中では `Config` が `Internal::Config`（dry-struct のスキーマ）に
解決されてしまうため、設定ローダーを参照するときは `::Config` と書く必要がある。

配信は 2 系統に分かれる。`index.html` / `feed.xml` / `manifest.json` は Workers
static assets、それ以外（mp3 とその兄弟ファイル・画像・`archives.csv`）は R2。
両方を同一オリジンで配信するため CORS 設定は不要。

R2 のキー構成:

| プレフィックス | 中身 | 退避対象 |
| --- | --- | --- |
| `episodes/` | mp3 と兄弟ファイル | ○（retention 超過分） |
| `assets/` | 画像などの恒久素材 | ×（消えるとサイトの画像が壊れる） |
| `archived/` | 退避済みエピソード | — |
| `archives.csv` | 台帳（公開経路の外） | — |

- **画像は R2 の `assets/` に置き、リポジトリにも配信成果物にも実体を持たない。**
  立ち絵などの版権素材を Git 管理下に置かずに済ませるため。`*.png` / `*.webp` は
  `.gitignore` 済みなので、static assets 方式だと publish する各環境に実体を手で
  配置する必要があった。
- 画像の `Cache-Control` は `max-age=3600`（`Site::ASSET_CACHE_CONTROL`）。
  ほとんど変わらないので長めに寝かせる。差し替えは 1 時間待つか、ファイル名を
  変えて参照を切り替える。

- オブジェクト名は渡された mp3 ファイル名をそのまま使うこと。日付から
  組み立て直すと slot（朝/昼/夜/深夜）が落ち、同日複数回のエピソードが同名衝突して
  上書きし合う。
- **mp3 とその兄弟ファイルは同じ `episodes/` プレフィックス配下に揃える。**
  再生ページの JS は mp3 URL の拡張子だけを差し替えて `.used.html` /
  `.transcript.txt` を引くため（`templates/index.html.erb`）、階層が違うと
  兄弟ファイルの URL が壊れる。`.transcript.txt` の内容は読み仮名化前の
  人間可読な台本原稿だが、公開ページ上では「文字起こし」として提示する
  （`Pipeline#episode_transcript_path`）。
- **retention 超過分の退避先は `episodes/` の外（`archived/`）にする。**
  `episodes/` 配下に置くと `run_worker_first` の対象なので Worker が R2 から配信し
  続け、公開を終えたはずの回が読めるままになる。
- `archives.csv` も `episodes/` の外に置く。台帳を公開オリジンから読めるようにする
  必要はない。ただし**プレフィックスの外に置くだけでは非公開にならない**:
  static assets に無いパスは Worker にフォールバックするため、`/archives.csv` が
  Worker へ届き R2 のルート直下から返ってしまう。Worker 側で配信可能な
  プレフィックス（`SERVABLE_PREFIXES`）を明示的に許可制にして塞ぐ。
- `ObjectNotFound`（`Internal::ObjectStorage`）は R2 実装固有の例外（`Aws::S3::Errors::*`）を
  ラップして返す共通例外。呼び出し側（`Site#read_ledger` 等）がストレージの実装を
  S3/R2 のどれに差し替えても、捕捉する例外クラスを変えずに済む。
- `object_exists?` は「オブジェクトが存在しない」と「確認自体に失敗した」を
  区別する。R2 は S3 互換 API なので HeadObject の 404 と 403 / 5xx が例外クラス
  として分かれ、文言マッチではなく型で判定できる。判定不能な失敗を「存在しない」
  扱いにすると、archives.csv を「初回で台帳が無い」と誤認し、既存台帳を新規 1 行で
  上書きして過去エピソード全履歴を消失させかねない。
- **R2 にサーバーサイドの move / rename は無い。** 退避は CopyObject +
  DeleteObject の 2 段構えで、copy の成功を確認してから delete する。途中で
  失敗したときは「元が残る」方に倒す（二重に存在するだけなら次回リトライで
  解消でき、公開物も壊れない）。逆順にすると復旧不能。退避先キーが決定的なので
  リトライは冪等（元が無く退避先にあれば `:already_moved` で何もしない）。
- `archived/` への退避は publish 時に自動で行われるが、実削除はされない。実削除は
  `Publisher#clean_archive` を明示的に呼んだときだけ行われる（ListObjectsV2 で
  列挙して DeleteObjects でバッチ削除。`wrangler r2 object delete` は
  プレフィックス指定に対応していない）。
- **素の `wrangler deploy` を使わない。** `wrangler.jsonc` に
  `assets.directory` を書くと、そのディレクトリの中身で公開サイト全体が
  置き換わる（デプロイはバージョン単位なので、生成済みの index.html /
  feed.xml が消える）。Worker のコードだけ直したい場合も同じ。
  `directory` を書かないことで素の deploy はエラーで止まり、
  `--assets <ステージング>` を渡す publish 経路だけが通るようにしている。
  Worker の変更を反映したいときも `--ui-only` を使う。
- **static assets のデプロイはバージョン単位で、ステージングに無いファイルは
  公開サイトから消える。** そのため `run` / `republish_ui` のどちらも、画像を
  含む全ファイルを毎回ステージングディレクトリへ書き出してから 1 回だけ
  `wrangler deploy` する。画像だけ載せ忘れると初回の `--ui-only` でアートワークが
  消える。
- `_headers` で `feed.xml` の `Content-Type` を `application/atom+xml; charset=utf-8`
  へ明示的に上書きする。拡張子ベースの既定推定だと `.xml` は `application/xml` 系に
  なるため。
- **`_headers` は `run_worker_first` のパス（`episodes/*`）に適用されない。**
  mp3 と兄弟ファイルの `Content-Type` は、Ruby 側が R2 の put 時に設定した値を
  Worker が `writeHttpMetadata` で反映することで初めて正しくなる。どちらかが
  欠けると `.used.html` が `application/octet-stream` で返るが、再生ページの JS は
  fetch 失敗を握り潰して「ニュース一覧はありません」と表示するため、
  **エラーにならず静かに壊れる**。
- カスタムドメインの追加は `wrangler deploy` 時に自動で行われ、DNS レコードと
  証明書も発行される。ただし**対象ホスト名に既存の CNAME レコードがあると失敗する**
  ので、移行時は先に既存レコードを削除する必要がある。
- static assets は `html_handling` の既定（`auto-trailing-slash`）により
  **`/index.html` を `/` へ 307 リダイレクトする**。そのため公開 URL としては
  正規形の `/` を使う（`Site#page_url`）。リダイレクトされる URL を feed の
  `<link>` や `og:url` に載せると、購読者とクローラが毎回余計な往復をする。
- static assets のデフォルト応答ヘッダーは実測で
  `cache-control: public, max-age=0, must-revalidate`。ETag による再検証前提
  なので、更新がすぐ届く一方で毎回条件付きリクエストが飛ぶ。
- Worker スクリプト（`src/index.js`）はこのリポジトリで唯一の JS 実行コードだが、
  JS のテスト基盤（Vitest 等）は導入していない。動作確認はプレビュー URL への
  `curl -I` と実機での再生確認で行う。配布されるファイルなのでコメントは書かず、
  以下に意図を記録する。
- Worker は資材プレフィックス（`episodes/*`）へのリクエストだけを処理する。
  それ以外は static assets 側が返すので Worker には到達しない。
- `get` に `onlyIf: request.headers` と `range: request.headers` をそのまま渡し、
  条件付きリクエストと Range を R2 側に解釈させる。音声のシークが Range に
  依存するため、`accept-ranges` と 206 応答時の `content-range` が要る。
- `writeHttpMetadata` は R2 オブジェクトのメタデータでヘッダーを上書きするため、
  `cache-control` の既定値を入れるのは必ずその後。順序を逆にすると R2 側に
  設定した値を握り潰す。
- `body` を持たない応答は条件付きリクエストが不成立だったケース。`If-Match` /
  `If-Unmodified-Since` が付いていたときだけ 412 を返し、それ以外は 304。
- **206 を返すのはリクエストに `Range` があったときだけ**にする。`get` に
  `range: request.headers` を渡すと、`Range` が無くても R2 は `object.range` に
  オブジェクト全体を表す値を入れて返すため、`object.range` の有無だけで分岐すると
  **全リクエストが 206 になる**。Slack などのクローラーは 206 を画像として扱わず、
  OGP 展開が黙って壊れる。
- `Publisher#run` 中に R2 操作または `wrangler deploy` が 1 つでも失敗したら
  即 abort する。公開物が index.html/feed.xml/manifest.json/archives.csv/mp3 の
  間で中途半端に不整合な状態のまま残らないようにするため。
  mp3 などの実体ファイルを R2 へ書き終えた後、`archives.csv` の内容はまだ
  書き込まずに `wrangler deploy`（`deploy_site`）を先に実行し、それが成功
  してから初めて `archives.csv` を書く（`write_ledger`）。逆順（先に
  `archives.csv` を書く）にすると、その後の `wrangler deploy` だけが失敗した
  ときに「台帳には新着行があるのに、公開ページはまだ反映されていない」状態で
  abort する。次回の実行では新旧の内容が既に一致しているため
  `newly_published` が false と判定され、`archive_episode_files` も通知
  （`EpisodeNotifier#notify`）も二度と行われなくなる。deploy を先に済ませて
  おけば、この種の取りこぼしが起きない。
- `Publisher#run` はストレージへの書き込みを一切始める前に
  `UsedNewsFormatter.ensure_valid!` で used_news のフォーマットを確定させる
  （後述「used_news の表示フォーマット」節参照）。検証・修復に失敗すればここで
  abort し、mp3 を含め何もアップロードしない。「Publisher#run 中に 1 つでも
  失敗したら即 abort する」という上記原則の一部として扱う。
- retention 超過分の実ファイル退避（`archive_episode_files`）は、新しい
  archives.csv・index.html/feed.xml の反映（`deploy_site` / `write_ledger`）が
  終わった**後**に行う。逆順（退避を先に）にすると、退避完了後の
  台帳・サイト反映が何らかの理由で失敗して abort した際、「エピソードファイルは
  退避済みなのに公開中の archives.csv/index.html は移動前の場所を参照したまま」
  という不整合が公開バケットに残り、該当回の再生・DL がリンク切れになる。
  この順序なら退避が失敗して `warn` に留まっても（`archive_episode_files` は
  fault-tolerant）、読者から見える台帳・ページは既に正しい状態になっている。
- `.used.html`（used_news を事前に HTML 化したもの）は `dist/` に実体を持たない
  ストレージ専用の派生物であり、`EPISODE_FILE_EXTENSIONS`（`.mp3`/`.used.txt`/
  `.transcript.txt` の3つ固定）には含めない。`archive_episode_files` では
  `.used.html` の退避を個別に fault-tolerant に行う（無ければ mv 失敗を警告に
  留めて継続する既存パターンを踏襲）。
- Atom の `<id>` は RFC 4151 の tag URI（`tag:<host>,<date>:<specific>`）を使う。
  `<id>` は RSS リーダー側の新着重複判定キーなので、**配信 URL を入れてはいけない**。
  URL を入れるとドメインやパス構成を変えた時点で全エントリの id が変わり、
  購読者に全エピソードが新着として再通知される。以前は mp3 URL を使っていたが、
  これは「feed.xml を動かさない key」として選ばれただけで、配信先から独立させる
  方が正しい。
  - entry: `tag:<host>,<エピソードの日付>:<mp3 のベース名>`。ベース名に slot が
    含まれるので、同日複数回でも衝突しない。
  - feed 自身: `tag:<host>,<Publisher::FEED_ID_DATE>:feed`。フィードの同一性を
    表すので日付は固定値で、**一度決めたら変えない**（変えると購読者が別フィード
    として扱う）。
  - `rel="self"` の href は実際の配信 URL のままにする（こちらは取得先なので
    tag URI にはしない）。
- tag URI の authority には発行日時点で管理していたドメインを使う（RFC 4151 は
  タグ付与者がその日付時点でそのドメインを管理していたことを要求する）。
  `Site#tag_authority` は `public_base` のホスト名を動的に導出する実装なので、
  `public_base` を変えると過去に発行済みのエントリの id も無条件に変わる。
- `cover_image` / `icon_image` は publish 時に static assets のステージングへ
  コピーされて配信される。手動アップロードは不要。
- `archives.csv` の `updated_at` 列は「publish を実行した時刻」ではなく
  「**コンテンツが変わった時刻**」を表す。`build_archives` は既存行と
  title / used_news を比較し、同一なら既存の `updated_at` を引き継ぐ。
  異なるとき（および新規エピソード）のみ現在時刻を入れる。
  `updated_at` は feed.xml の `<updated>` の源であり、ここが「実行時刻」だと
  内容が同じ再 publish や `--ui-only` でも `<updated>` が動いて購読者全員に
  誤った新着通知が飛ぶ。以前はこれを「既存 slot へ再 publish しない」という
  運用ルールで回避していたが、値のセマンティクス自体を修正して解消した。
- 既存の `updated_at` が空文字の行（過去に空で記録されたもの）からは引き継がず
  現在時刻を入れる。空のまま引き継ぐと `<updated>` が空になり Atom として壊れる。
- `updated_at` は `build_archives` の並び替えキー（`[date, updated_at]`）でもある
  ため、引き継ぎは表示順の安定にも効く。

#### Web Push 通知（購読者管理・送信は Worker 側に同居）

- 新規 episode の publish を Web Push で知らせる機能。`config.yaml` の任意セクション
  `web_push`（`vapid_public_key` のみ）が無ければ完全に無効化される。独立サービスへの
  切り出しはせず、既存の配信基盤（Cloudflare Workers + R2 + D1）に同居させている
  （購読者管理も送信もドメイン・ストレージ・実行環境がすでに揃っているため）。
- 購読者ストアは Cloudflare D1。KV は書き込み 1,000/日の制限があり全件読み出しに
  list + N回get が必要になる。Durable Objects は Cloudflare 公式ガイドが推す構成
  だがエージェント単位の状態管理を前提にしたもので、今回のような「全購読者への
  一斉配信リスト」には D1（`SELECT` 1回で全件取得）の方が素直。
- VAPID 署名・ペイロード暗号化は `web-push` npm パッケージ（pushpad/web-push）を
  使う。ただし `sendNotification()` は内部で Node の `https` モジュールへ直接
  リクエストを投げる作りで、Workers の `nodejs_compat` 下でも素直に動く保証がない。
  代わりに `generateRequestDetails(subscription, payload)` で
  `{endpoint, method, headers, body}` を組み立てるだけに留め、実際の送信は
  Workers 組み込みの `fetch()` で行う。VAPID の ES256 署名（`crypto.createECDH`
  等）とペイロード暗号化（ECDH + HKDF + AES-GCM）は Node 標準の `crypto`/`Buffer`
  に依存するため、`wrangler.jsonc` の `compatibility_flags: ["nodejs_compat"]`
  が必須（Vitest 上での実地確認で、この構成が実際に動くことを確認済み）。
- 購読の宛先が 404/410 を返したら、その `endpoint` を D1 から削除する
  （ブラウザ側で購読解除・ブラウザデータ削除等が起きた購読は自然に消える）。
- `POST /subscribe` の `endpoint` は既知の Push サービス（FCM/Mozilla/Apple）の
  オリジンだけを許可する。ここを検証しないと任意のホストを endpoint として
  登録でき、`/notify` がその都度そこへ `fetch` してしまう（SSRF・D1の汚染）。
  一件でも不正な endpoint への送信が失敗しても他の購読者への配信を止めない
  設計（`handleNotify` の per-row try/catch）と合わせて、被害を最小化している。
- `Internal::EpisodeNotifier#notify` は Worker からのレスポンスが非 2xx
  （共有シークレットのずれによる 401 等）でも例外を投げないため、レスポンスの
  ステータスを明示的に見て `warn` する。見ないと Worker 側の認証エラーが
  `Publisher#run` の "done" 表示に隠れて気づかれない。
- `templates/sw.js.erb`（Service Worker）は `Publisher#deploy_site`
  （`lib/publisher.rb`）の第4の生成物としてステージングディレクトリに書き出す。
  `Internal::Site#deploy` は渡されたディレクトリの中身でバージョン単位の全置換を
  行うため、ここに含めないと次回の `--ui-only` 実行だけで `sw.js` が公開サイトから
  消え、ブラウザに登録済みの Service Worker が更新されず購読が実質的に壊れる
  （気づきにくい形の障害になるため、この一文だけは明記しておく）。`Config.web_push`
  の有無で書き出しを分岐させず常に書き出しているのはこのためで、将来 `web_push`
  セクションを config.yaml から外しても sw.js は消えない（`render_sw` 自体が
  `Config.web_push` に依存していない）。
- 通知の要否は `updated_at` の変化ではなく、`build_archives` が返す
  `newly_published`（`content_changed?` の結果）で判定する。`updated_at` の
  更新セマンティクス自体は「feed.xml の `<updated>` を誤って動かさない」ためのもの
  で、Web Push の要否とは別の関心事だが、判定に使う条件（新規 or 変化）は同一なので
  `content_changed?` 一箇所に集約し、`updated_at_for` もその結果を受け取るだけに
  している（同じ条件を2箇所に別々に持つと、片方だけ変更したときに feed.xml の
  `<updated>` が動くタイミングと通知が飛ぶタイミングがずれるため）。
  `#republish_ui` は `build_archives` を呼ばず `fetch_existing_archives` のみを
  使うため、`--ui-only` では判定自体が発生せず通知も発火しない。
- `content_changed?` は `used_news_given`（`Publisher#run` の `used_txt_path` が
  渡されたかどうか）も見る。`used_txt_path` が nil または実体が既に無い場合、
  `load_and_validate_used_news` は空文字列を返すが、これは「used_news を意図的に
  空へ変更した」わけではない。`used_news_given` が false のときは used_news の
  差分を比較材料にせず、title の変化だけで判定する。そうしないと、work/ の掃除等で
  used.txt がローカルから消えただけの再 publish を「内容変更あり」と誤検知し、
  無関係な購読者へ再通知してしまう。
- `Publisher#run` の「1つでも失敗したら即 abort する」原則（本節冒頭）の例外として、
  Web Push の通知送信だけは失敗しても `abort` せず `warn` に留める
  （`Internal::EpisodeNotifier#notify`）。`deploy_site` が既に成功した後に呼ぶため、
  通知の成否は公開物の整合性に影響しない。
- `/notify` の認証は共有シークレットを Worker secret（`wrangler secret put`）に置き、
  `crypto.subtle` の HMAC-SHA256 で検証する。config.yaml は「機密を持たないから
  git 追跡してよい」という前提で運用しているため、ここにシークレットを書くとその
  前提が崩れる。VAPID 公開鍵は秘密ではない（購読ボタンの JS がブラウザへそのまま
  渡す値）ので config.yaml に置いて問題ない。
- Workers のサブリクエスト上限は 50/リクエスト。購読者が少数のうちは全件へ
  ループで `fetch` するだけで足りるが、規模が増えた場合はバッチ分割や Cron
  Trigger によるキュー処理の検討が必要になる（現時点では未実装）。
- `src/index.js` は `web_push.js` を無条件に static import するため、
  `config.yaml` の `web_push` セクションの有無に関わらず、deploy する限り
  `node_modules/web-push`（`npm install` 済み）が必須になる。これが無いまま
  `wrangler deploy` を実行すると esbuild の解決エラーでパイプライン終盤の
  deploy 段階まで進んでから初めて落ちる。これを避けるため、`miyamai_news.rb`
  は起動時に `Internal::NodeDeps.validate_wrangler_build!` を呼び（実際に deploy
  へ到達する起動に限る。呼び出し条件は次項参照）、`wrangler deploy --dry-run`
  （空の一時ディレクトリを `--assets` に渡し、
  実アップロードなしでビルドと設定検証だけを行わせる）で fail fast させている。
  `node_modules/web-push` の有無だけを見るファイル存在チェックにせず実際に
  `wrangler` を動かしているのは、依存の欠落に限らず `wrangler.jsonc` の
  設定不備等、ビルド段階で起きうる失敗全般を検出するため。`Site#deploy`
  （`lib/internal/site.rb`）と同じ bare `wrangler` 呼び出しを使う必要がある。
  `npx wrangler` にすると `node_modules/.bin` 経由の別バージョンを検証して
  しまい、実際の deploy が使うバイナリ（PATH 解決、環境によってはグローバル
  インストール版）と食い違う。
- 上記の validation は `--ui-only` または `Pipeline.reaches?("publish", ARGS)`
  が真の場合だけ呼ぶ。`Pipeline.target_mode_for(args)`（`--clean` 系・
  `--ui-only`・`--confirm-fetch`・`--restore-fetch` は pipeline.mode と無関係な
  独立コマンドなので nil を返す）と、それを `Config::MODE_ORDER` で比較する
  `Pipeline.reaches?(mode, args)` を `Pipeline` に持たせている。`Config` では
  なく `Pipeline` に置くのは、CLI フラグ（`args`）と mode の対応づけが
  `Pipeline#run` 自身の知識だから。`--digest-only` / `--script-only` /
  `--synthesize-only` はこの判定で正しく対象外になる（`pipeline.mode:
  publish` の環境でも deploy 前で止まるため）。`--ui-only` は mode の概念の
  外側で deploy するため、呼び出し側で明示的に特別扱いする。

### 旧 GCS feed の凍結（移行告知）

旧公開先（`gs://nidodm-miyamai-news/feed.xml`）は、移転告知だけを含む静的な
Atom に一度だけ差し替えて凍結した。生成コードは持たない（一度きりの作業で、
中身も旧 feed から引き継ぐものが無いため）。以後この feed は更新しない。

- **`<id>` は旧 URL のまま変えない。** ここを変えるとリーダーが別フィードとして
  扱い、既存購読者に告知が届かない。逆に entry の `<id>` は新規発行の tag URI に
  して、過去エピソードのどれとも衝突させない。
- **過去エピソードのエントリは載せない。** GCS を撤去すると mp3 が消えて
  リンク切れのエントリだけが残るし、過去回は新 feed 側にある。伝えたいのは
  移転の事実だけなので告知 1 件に絞る。
- `<updated>` を動かさないと新着として拾われないので、凍結時に一度だけ動かす
  （「新規 episode の publish 以外で feed.xml を更新しない」原則に対する、
  意図的な一度きりの例外）。
- 告知に添える画像は旧公開先（GCS）へ置く。新ドメイン側に置くと、移行先に
  何かあったときに告知の画像まで一緒に見えなくなる。
- **Atom に移転を表す標準の仕組みは無い。** RFC 4287 の `rel` は
  `alternate`/`related`/`self`/`enclosure`/`via` のみで、仕様は rel が読み手に
  何の動作も要求しないと明言している。`rel="self"` と `canonical` の書き換えは
  best effort で、確実なのは「人間に読ませて再購読してもらう」経路だけ。

### LastFetchStore / 収集 window（last_fetch.json）

- インスタンス状態を持たず、work_dir を渡すだけのモジュール関数の集まりにしている。
  前回 pending の確定/ロールバックを人間に尋ねる `resolve_pending!` も同じモジュールに
  同居させているのは、状態を握る当のモジュールが対話込みの解決まで面倒を見た方が
  凝集度が高いため。
- `read_data` は、last_fetch.json が valid JSON だが Hash でない壊れ方をしていた場合、
  デフォルト値で上書きせず abort する。上書きすると手動修復・AI による復旧の余地を
  失うため。
- `mark_pending!` は Undo バッファ（rollback_at/last_op）をクリアする。新規収集の発生は
  人間の操作ではない（Undo 対象にしない）ため。
- `--publish-only` は新規 fetch をせず既存成果物を公開するだけなので、収集 window を
  新しい時刻に進めてはいけない（fetch していない時刻で確定すると取りこぼす）。pending が
  残っていれば公開＝確定として昇格させ、無ければ何もしない。
- 前回 pending の確定/ロールバックは、収集の起点(since)を確定する直前＝新規 fetch が
  実際に走る直前に ScriptGenerator が自分で尋ねる。既存 news スナップショットを再利用する
  実行（例: `--script-only` の後にフラグなしで synthesize へ進む）は fetch しないので、
  確認は出ない。`auto_confirm` は CI 等の非対話実行で確認を飛ばして自動確定するかどうか。
- 収集 window（confirmed_at）は実行が完了しただけでは進まない。人間が成果物
  （facts/台本/mp3）を確認し「進めてよい」と判断した時点で初めて確定する。
  publish だけは公開自体が確定行為なので例外（`confirm_immediately!` で即時確定）。
- `Pipeline#run_confirm_fetch_command` は `LastFetchStore.confirm!`（状態変更）の
  前に `Config.validate_sections!("collect")` を呼ぶ。`confirm!` の後で読む
  `ScriptGenerator.record_used_news_history!` が `Config.collect` を参照するため、
  検証を先に済ませないと「pending は解消済みなのに履歴記録だけ失敗する」
  中途半端な状態になり、`pending_episode` が既に消えていて後から追記もできない。
- `confirm!`/`rollback!` は、直前の `confirmed_at`/`pending_at` を捨てる前に
  `rollback_at` へ退避してから `last_op` を記録する。誤って `confirm!`/`rollback!` を
  呼んでしまっても `restore!` で1段だけ巻き戻せるようにするため。
- `resolve_pending!` の確認プロンプトで無回答（Enter/N）の既定はロールバック
  （＝ confirmed_at を進めない）。理由: 記事を取りこぼす（confirmed_at を進めて
  しまうと二度と収集対象に戻らない）よりも、次回また同じ記事が候補に上がる
  （重複・再確認の手間）方が安全という判断。
- 新規 fetch が起きた事実は `ScriptGenerator#load_or_collect_news` が
  `news_collected_path` へ書き込むのと同じタイミングで `mark_pending!` を呼び、
  即座に `last_fetch.json` へ永続化する（実行完了時ではなく fetch 完了の瞬間）。
  `fetched_news?`（`@fetched_news` インスタンス変数）はプロセスローカルな状態で、
  そのプロセスが後続の selector 等で中断・再起動されると失われる。中断後に
  別プロセスが `news_collected_path` の reuse だけで publish まで到達した場合、
  そのプロセスの `fetched_news?` は false になるが、`mark_pending!` が既に
  fetch 時点で書き込み済みなので `LastFetchStore.confirm!` が pending を
  正しく見つけて `confirmed_at`・履歴記録を引き継げる。実行完了時にまとめて
  pending 化する設計だと、fetch した張本人のプロセスが完了前に終了した場合に
  この事実がどこにも残らず、`confirmed_at` が進まないまま同じ記事が翌回に
  再登場し、かつ紹介済み履歴にも記録されない（回またぎの二重紹介）という
  不具合になる。

### ScriptGenerator / AI パイプライン

- 各ステップ（収集・選定・facts 抽出・script+used 生成・整形）は work_dir 内の
  中間ファイルの有無で再利用を判断する。途中でクラッシュしても、存在する中間
  ファイルはそのまま使い、続きから再実行できる。
- `OPENING_GREETING`（"宮舞モカです。"）は台本の挨拶文であると同時に、
  `strip_preamble` が AI 出力の前置き除去に使う目印（アンカー）でもある。
- `feed_cache/` ディレクトリ（および移行期の旧 `feed_cache.json`）と `last_fetch.json`
  は回をまたいで永続する状態で、`clean` は対象にしない（`work_globs` が列挙する回ごとの
  中間ファイルのみが削除対象。ホワイトリスト方式なので状態ファイルは自動的に残る）。
- 収集 window の起点として記録する時刻は、実行完了時刻ではなく収集開始時刻
  （`@now`）。実行に時間がかかった場合、開始〜完了の間に seen_at が刻まれた記事を
  次回取りこぼさないため。
- ニュースの重複除去はタイトル基準（大文字小文字・空白を無視）。同一タイトルが
  複数ソースにまたがる場合、`priority: high` のソース由来の entry を代表として
  残す（config での記載順によらず、一次情報源の priority ラベル・URL が選定 AI
  に渡るようにするため）。priority が同順位の entry 同士では、config の
  `rss_feed_sources` 記載順（`items_per_source.flatten` 順）で先勝ち。
- `fetched_news?` は「この実行で一度でも新規 RSS 収集が発生したか」を表す
  フラグで、呼び出し側（`Pipeline#run_full`）が publish 到達時に
  `confirm_immediately!`（fetch あり）と `confirm!`（fetch なし、pending
  ベース）のどちらの経路で収集window を確定するか判断するのに使う。
  digest→generate と同一インスタンスで複数回工程を呼んでも、一度 true に
  なったら false に戻らない。収集window の pending 化自体は
  `load_or_collect_news` が fetch 完了時に行うため（前掲「LastFetchStore /
  収集window」節参照）、このフラグ自体はプロセスをまたいで pending 化の要否を
  判断する用途には使わない。
- writer ステップ（台本執筆）は、既に抽出済みの facts シートに基づいて執筆させる
  よう**プロンプト側**で指示している（Web への再アクセスによる手戻り・情報の
  食い違いを防ぐため）。`allowedTools` は全 AI CLI 呼び出しで共通の
  `"Read Write WebFetch"` に固定しており（`Internal::AiCli.run` 参照）、
  呼び出し元ごとにツールを絞ってはいない（実害のあるツールではなく、
  用途ごとに出し分ける利点が薄いため）。
- `category_details` は「AI への執筆方針の指示」と「used_news のカテゴリ見出し
  （`## ラベル名`）として使う正式なラベル一覧」を兼ねる。`UsedNewsFormatter.strip_preamble`
  （`ScriptGenerator` ではなく `UsedNewsFormatter` 側にある。後述「used_news の
  表示フォーマット」節参照）はこの「##」見出しが本文の先頭に来る構造に依存しているため、
  category_details のラベル文言・見出し規則を変える際は合わせて確認すること。
  （`strip_facts_preamble` も `##` をアンカーに含むが、used 用と facts 用は別モジュール・
  別ファイルなので取り違えは起きない。）
- used_news のフォーマット検証・AI修復は ScriptGenerator の責務ではない
  （`UsedNewsFormatter` 参照）。ScriptGenerator は writer/extractor が書いた
  used_news をそのまま work/ に残す。
- AI CLI の出力には、プロンプトで前置き禁止を指示していても、まれに前置き文
  （「整形しました」等の応答）が混入する。`strip_preamble` /
  `strip_facts_preamble` / `UsedNewsFormatter.strip_preamble` は、いずれもこれを
  機械的なアンカー探索（挨拶文/見出し等）で除去する対策。
- RSS ソースの `priority` は選定 AI への判断材料（ヒント）に過ぎず、掲載/除外を
  保証するものではない。
- フィード取得（`FeedCache#fetch`）が 1 つでも失敗したら実行全体を中断する。
  ニュースが揃わないまま後段の AI 呼び出しに進み、不完全な情報を元にトークンを
  浪費するのを防ぐため。

### EpisodeLogger（実行ログ）

AI CLI（selector/extractor/writer/format/used_fix）・VOICEPEAK・HTTP フェッチの
stdout/stderr・所要時間・リトライ回数等は、従来 `warn` の文字列に断片的に出るのみで
構造化された形では残っていなかった。`Internal::EpisodeLogger`
（`lib/internal/episode_logger.rb`）はこれを `work/<date_tag>_<slot>.log` に
プレーンテキストで追記するだけの薄い記録係で、以下の不変条件を持つ。

- **Config と同じモジュールレベルのグローバル状態**。`Pipeline#setup_episode!`
  内で episode 確定後・`WORK_DIR` 作成後に一度だけ `configure(path)` する。
  `AiCli`（呼び出し元のインスタンス状態を参照しない設計）や、`Publisher` 経由で
  呼ばれ episode の概念を持たない `UsedNewsFormatter`、`FeedCache` の下位層で
  episode を知らない `HttpFetcher` など、経路の異なる全呼び出し元に個別に
  `log_path` を注入するとシグネチャ変更が広範囲に波及するため、Config と同じ
  「一度設定してどこからでも参照する」パターンを踏襲した。
- `configure` されるまで（`--clean`/`--clean-archive`/`--ui-only`/
  `--confirm-fetch`/`--restore-fetch` など episode 生成前に早期 return する経路）
  は `record` が no-op になる。これらの経路は AI CLI や VOICEPEAK を呼ばないため
  実害はない。
- **常に追記（truncate しない）**。`--digest-only`→`--script-only`→
  `--synthesize-only`→`--publish-only` を別プロセスで順に実行する運用がある
  ため、`configure` のたびに切り詰めると前段の実行ログが消えてしまう。
- **`ScriptGenerator#fetch_sources_in_parallel` は複数スレッドから同時に
  `HttpFetcher#get` を呼ぶ**（既存の前提。前掲「FeedCache」節参照）ため、
  `record` 内部の Mutex で1エントリ（ヘッダー行＋任意の本文ブロック）の書き込みを
  synchronize している。ロック保持時間を最小化するため、文字列を組み立てて
  から1回だけ `File.open(path, "a")` する。
- `record` 自体は計測を一切行わない。呼び出し元（`AiCli`/`VoiceSynthesizer`/
  `HttpFetcher`）が `EpisodeLogger.start_timer`（`Process.clock_gettime
  (Process::CLOCK_MONOTONIC)` を返すだけの薄いヘルパー）で開始時刻を取り、
  処理の直後に `EpisodeLogger.elapsed_since(start)` で経過秒数を計算して
  `record` に渡す（`Time.now` の差ではなく monotonic clock を使うのは NTP
  補正の影響を受けないため）。ブロックで包む API（`measure { ... }` 相当）は、
  呼び出し元の主処理がブロックの中に埋もれて読みにくくなるため採用していない。
- `Internal::AiCli.run_with_spinner` は stdout/stderr に加え `log_meta`
  （`bin`/`model` をまとめたハッシュ）・`exit_code`・`duration_sec` を記録
  するが、実行した argv（`cmd`）自体はログに含めない。`bin != "claude"`
  （agy 等）の分岐ではプロンプト本文が `cmd` の一部（`-p` の直後の引数）
  として渡るため、そのまま出すとプロンプト全文がログに漏れる（`claude` は
  stdin 経由なので `cmd` には混ざらないが、`bin` 分岐ごとに扱いを変えるのは
  煩雑なため一律で `cmd` は出さない）。`bin`/`model` を `run_with_spinner`
  に個別のキーワード引数として渡さず `log_meta:` 1つにまとめているのは、
  ログ用の付随情報であることを1箇所で明示するため（レビュー指摘を反映）。
- `agy`（非 `claude` 分岐で使う AI CLI）の `-p`/`--print`/`--prompt` は
  値必須の引数で、stdin からプロンプトを読む経路を持たない。`agy -p
  < /dev/null` は `flag needs an argument: -p` で即座に失敗し、`agy -p ""`
  も stdin を読まず `promptLength=0` の empty prompt エラーになる（検証
  済み）。そのためプロンプト全文を argv 経由で渡す現状の実装は、ARG_MAX
  超過リスク（Issue #90）を認識した上での制約であり、stdin/一時ファイルへの
  切り替えでは解決できない。
- `work_globs(work_dir)` は `work/*.log` を返し、`Pipeline#clean_work_dir` が
  他コンポーネントの `work_globs` と合算して `--clean` の対象にする
  （`ScriptGenerator`/`VoiceSynthesizer` と同じホワイトリスト方式）。

### used_news の表示フォーマット（Markdown サブセット）

再生ページ（index.html）と feed.xml の「この回で紹介したニュース」欄（used_news）は、
以下の限定 Markdown サブセットで書き、構造化 HTML に変換して表示する。**この文法の
唯一の実装は Ruby 側（`lib/internal/used_news_markdown.rb` の `UsedNewsMarkdown`）**。
JS 側に同じ文法のパーサは存在しない（後述）。パーサ側のコメントはこの節を参照するだけに
し、文法の説明を各所に散らさない。

- 行単位で解釈する（ブロックレベルのみ。インライン強調・コードは扱わない）。

  | 種別 | マッチ | 変換 |
  |---|---|---|
  | カテゴリ見出し | `^##\s+(.+?)\s*$` | `<div class="news-cat">…</div>`（見出しタグにしない） |
  | 記事タイトル | `^###\s+\[(.+)\]\((\S+)\)\s*$`（`[...]` は貪欲） | `<div class="news-item"><div class="news-title">…</div>`。$1=タイトル/$2=URL |
  | メタ行 | `^\s*\((.+)\)\s*$` | 直近項目の `<div class="news-meta">(…)</div>` |
  | 要約行 | 上記いずれにもマッチしない空でない行 | 直近項目の `<p class="news-sum">` |
  | 空行 | — | 項目区切り（無視） |

- カテゴリ・記事タイトルとも**見出しタグ（h2/h3）を使わず** `<div>` + CSS で表現する。
  used_news はページ全体の中に埋め込まれるので、`##`/`###` を h タグにするとページの
  見出しアウトライン（h1 タイトル / h2「この回で紹介したニュース」）に混ざるため。
- **貪欲マッチの理由**: タイトルに `]` や `)` を含む記事がある（例
  `GitHub - ayghri/i-have-adhd: Claude Code skill [beta]`）。URL に空白は入らない前提
  なので、最後の `](URL)` を境界にできる。
- **エスケープ**: タイトル・要約・メタは HTML エスケープしてから埋め込む。URL は
  `http/https` で始まる場合のみ `<a>` 化する（`javascript:` 等はリンクにせずプレーン
  表示。XSS 防止）。
- **失敗（ok=false）条件**: (a) `##` 見出しが 1 つも無い、(b) `### [...](...)` タイトル行が
  1 つも無い、(c) 見出しの前に孤立したタイトルがある等の破綻、(d) 例外発生。

#### 表示の仕組み: Ruby が事前 HTML 化する（JS は二重パースしない）

以前は Ruby（feed.xml 用）と JS（index.html 用）の両方に同じ Markdown サブセットの
パーサを実装していたが、二重実装になるためやめた。現在は **Publisher が publish 時に
`UsedNewsMarkdown.render` で used_news を HTML 化し、`.used.html` としてストレージへ
事前アップロードする**（`Publisher#upload_used_news_html`）。

- `.used.html` は `UsedNewsMarkdown.render` が `ok` のときだけ作る。`ok=false`
  （パース不能）のときはアップロード自体をスキップする。
- 再生ページの JS（`loadNews`）は `.used.html` を fetch し、200 ならそのまま
  `innerHTML` に差し込むだけで、JS 側にパーサは存在しない。`.used.html` が
  404・fetch 失敗のときだけ `.used.txt` を fetch し、`<pre>` + URL リンク化
  （`linkify`）の生テキスト表示にフォールバックする。
- feed.xml は同じ `UsedNewsMarkdown.render` を `Publisher#used_news_html` 経由で呼ぶ。
  ただし `ok=false` 時の扱いは `.used.html` 用と異なり、`fallback_used_news_html`
  （URL リンク化 + `<br>`）で content を埋める（feed の content は空でも許容される
  ため。`.used.html` 側は「無ければ JS が `.used.txt` にフォールバックする」ため
  作らない、という判断）。
- **旧フォーマットとの後方互換**: 移行前の `.used.txt`（`■` 見出し + `・タイトル` +
  独立 URL 行）は `ok=false` になり、ストレージ上にも `.used.html` は存在しない
  （今回の変更以降に publish された回でしか生成されない）。JS の 404 フォールバックが
  これを吸収し、ストレージに残る過去回は壊れず従来どおり表示される。

#### フォーマット保証は Publisher の責務（ScriptGenerator ではない）

used_news のフォーマットが厳密に正しいかどうかを検証・保証する責務は
**`ScriptGenerator` ではなく `UsedNewsFormatter`**（`lib/internal/used_news_formatter.rb`）
にあり、**Publisher がストレージへの書き込みを始める前に呼ぶ**（`UsedNewsFormatter.ensure_valid!`）。

- `ScriptGenerator` は「## カテゴリ / ### [タイトル](URL)」形式のそれっぽい
  Markdown を生成するだけで、前置き除去も含めてフォーマットには一切手を入れない
  （work/ の中間ファイルには AI が書いた生のテキストがそのまま残る）。
- `UsedNewsFormatter.ensure_valid!(text)` は、前置き除去 → `UsedNewsMarkdown.render`
  で検証 → 崩れていれば軽量モデルで修復、の順に整えて返す。修復後もフォーマットが
  直らなければ **`abort` し、`Publisher#run` 全体を止める**（ストレージへの書き込みは何も
  始まっていない状態で止まるよう、`Publisher#run` の先頭でこの検証を呼んでいる。
  「新規エピソードで壊れた used_news がそのまま公開される」事態を防ぐため。
  used_news が無い回（空文字列）は早期 return し、AI 呼び出し・abort を行わない）。
- 修復 AI の呼び出しは `templates/fix_format.prompt.erb`。出力は stdout ではなく
  tmp file（Write→Read）で受け渡す（stdout は前置き・コードフェンス等のノイズが
  混入しやすいため）。修復 AI が記事を捏造/欠落させないよう、整形後の URL 集合が
  入力と一致することを Ruby 側で機械的に強制する（`preserves_urls?`）。
- 修復の最大リトライ回数は `ai_agent.used_fix_max_retries`（既定 2）で config 化
  している。`0` を指定すると `Integer#times` が一度も回らず、AI を一切呼ばずに
  即座に修復失敗として扱う（＝修復機能そのものを無効化できる）。
- AI CLI の実行ロジックは `Internal::AiCli`（`lib/internal/ai_cli.rb`）に集約して
  あり、`ScriptGenerator`（selector/extractor/writer/format）と `UsedNewsFormatter`
  （修復）の両方が `Internal::AiCli.run`/`.model_for` を直接呼ぶ（ラッパーは持たない）。
  非致命化パラメータは `fatal:`（既定 `true`）で統一し、失敗時に abort するかどうかを
  直接的に表す。`effort_override:`（既定 `:default`）は claude 用の effort を
  呼び出し元で明示的に差し替えるための引数で、`nil` を渡すと `Config.ai_agent.effort`
  を使う。
- `UsedNewsFormatter::PROMPT_CONTEXT`（空オブジェクト）で足りるのは、
  `fix_format.prompt.erb` が `format_spec`/`broken_content`/`output_path` のローカル
  変数のみを参照し、`ScriptGenerator`/`Publisher` いずれのインスタンスメソッドにも
  依存しないため。
- `strip_preamble` は、想定した「## から始まる」構造が見つからなければ入力をそのまま
  返す。機械的に何かを削ぎ落として誤魔化すより、人間が壊れた入力に気づける形にする
  ため。
- `bin != "claude"`（agy 等）の分岐では `--add-dir` に実行時のカレントディレクトリ
  （`Dir.pwd`）を明示的に渡す。`--add-dir` を渡さない場合、agy が実行中のプロジェクト
  ディレクトリを安定して認識できず `~/.gemini/antigravity-cli` 等をワークスペースと
  誤認識することを確認したため、ワークスペースを明示する目的で渡している。ただし
  これ自体は下記の「出力フォーマット指示が無視される」不具合の解決策ではない
  （`--add-dir` を渡した状態でも同じ不具合が再現することを確認済み）。
- agy（`gemini-3.6-flash-high` 等）は、プロンプトの前半（ペルソナ・入力データ・
  分類ルール・除外ルール）には従う一方、**末尾に書いた「出力フォーマット」の指示
  （絶対パスへの書き込み・見出しや箇条書きの形式・要約や書き換え禁止）を一貫して
  無視することがある**。selector で観測した際は、指定した絶対パスへの書き込みが
  行われず、選定結果全文がそのまま stdout のテキスト応答として返る形で現れた
  （exit code は 0 のまま、stderr にも手がかりは出ない。候補ニュースの入力サイズを
  減らしても再現し、`--add-dir` の有無でも変わらなかったため、入力サイズや
  ワークスペース解決が原因ではない）。extractor/writer は書き込み指示に「Write
  ツールで」とツール名を明記しているのに対し、selector には元々それが無かった
  （「書き出してください」という曖昧な文言のみ）。selector にも同様にツール名を
  明記し、かつ書き込み先パスの指示をプロンプト冒頭（タスク説明の直後）へ移すことで
  緩和した（selector.prompt.erb 参照）。あわせて、候補ニュース本文をプロンプトに
  文字列として埋め込むのをやめ、`news_collected_path` の絶対パスを渡して
  「Read ツールで読め」と指示する形に変更した（プロンプト全体のサイズを削り、
  書き込み指示の相対的な埋没を避けるため）。

### UsedNewsHistory（紹介済みニュース履歴）

- なぜ必要か: `last_fetched_at` を跨いで別ソースが同じ話題を配信すると、FeedCache の
  `seen_at` が振り直されて「新着」扱いになり、直前の回で紹介したニュースが次の回でも
  selector に選ばれてしまう（回またぎの二重紹介）。`dedup_by_title` は同一実行内しか
  効かない。そこで直近 N 回（`collect.used_news_history_episodes`、既定4）の紹介済み
  ニュースを `work/used_news_history/<episode_key>.txt` に貯め、selector プロンプトの
  `<recently_used>` として渡し、AI に link 一致・話題一致で避けさせる（Ruby 側の機械
  reject ではなくプロンプトベース）。
- 要約を持たせる理由: 別ソース・別 URL でも「同じ話題」を AI が判断できるよう、used_news
  自体に 1〜2 文の短い要約をタイトル直下に載せる。副次的に再生ページ・feed の「この回で
  紹介したニュース」欄にも要約が出る。表示側（`.used.html` を作る `UsedNewsMarkdown` /
  feed.xml の `Publisher#used_news_html`）は used_news を Markdown サブセットとして
  構造化パースする（文法は上の「used_news の表示フォーマット」節参照。要約行は
  「見出し・メタ・空行のいずれでもない行」として拾う）。`UsedNewsFormatter.strip_preamble`
  は先頭の `##` 起点なので、要約を `### タイトル` 配下に置く限り前置き除去には影響しない。
- used_news を書く工程は 2 つある。extractor が facts と一緒に**暫定版**を
  `news_used_provisional_<episode_key>.txt`（`ScriptGenerator.provisional_used_news_path`）
  に書き（`templates/extractor.prompt.erb`。digest mode の到達点でも履歴の元データを残す
  ため。候補として facts 化した全ニュースが対象）、writer 到達時に**別パス**
  `news_used_<episode_key>.txt`（`ScriptGenerator.used_news_path`。`templates/writer.prompt.erb`。
  台本で実際に紹介したもの）へ**確定版**を新規に書く。両パスとも `news_*.txt` グロブに
  含まれ `--clean` 対象。`record_used_news_history!` は確定版があればそれを、無ければ
  暫定版を使う（＝confirm 時にどちらが存在するかで履歴に入るものが決まる）。これにより
  digest mode 運用でも履歴が溜まる（used_news が全く無い digest なら記録するものが無く、
  `record!` は `File.exist?` ガードでスキップする）。暫定 used は履歴用の副産物なので、
  extractor が書き損ねても digest は止めない（`finalize_optional_used_news` は無ければ
  何もしない）。確定 used を書く writer 側はファイル欠落なら従来どおり abort する
  （不完全なまま後段へ進ませない）。**暫定版と確定版を別パスにしているのは、同一パスへの
  上書きに依存すると writer が Write を怠っても extractor の暫定版がそのまま存在し続けて
  existence チェックを通過してしまい、確定版として素通りしてしまうため**（issue #83。
  以前は同一パスだった）。フォーマット検証・AI 修復は行わない（前掲「used_news の
  表示フォーマット」節参照。ScriptGenerator は生テキストをそのまま残し、Publisher が
  公開直前に検証・修復・失敗時 abort を行う）。
- 履歴は機械パースしない: 用途は selector プロンプトへの丸ごと埋め込みなので、used_news の
  テキストをそのまま置く。ただし link はプロンプトのノイズにしかならないので履歴コピー時に
  除去する（`strip_links`）。新フォーマットでは URL がタイトル行 `### [タイトル](URL)` に
  内包されるので、`### [タイトル](URL)` → `### タイトル` に畳んで URL だけ落とす（移行期に
  混じりうる旧・独立 URL 行の除去も残す）。公開用 `dist/*.used.txt` には link を残す。
- 保存場所と clean 非対象: `work/used_news_history/` は feed_cache/・last_fetch.json と同じ
  回をまたぐ永続状態。`ScriptGenerator.work_globs` のホワイトリスト（`news_*.txt` 等）に
  載らないので `clean` で消えない。中間ファイル `news_used_*.txt` は `news_*.txt` グロブで
  clean 消去されるため、履歴は必ず別ディレクトリへコピーする。
- `episode_sort_key` は未知形式の episode_key を末尾（最古扱い）に寄せる。壊れた
  key が混じっても、ソートに基づく削除・並べ替え処理自体が壊れないようにするため。
- 1 回の単位とソート: `<date_tag>_<slot>`（episode_key）。同一 key への再記録は上書き（冪等）。
  FIFO は `(date_tag, Slot.sort_key(slot))` で新しい順に判定する（mtime 非依存）。`midnight`
  は `broadcast_date` で前日回に寄るため、同一 date_tag 内では日内の最後になる。
- 追記タイミングと不変条件: 収集 window の **confirm 時のみ**追記する（rollback された回は
  読者に届いていないので履歴に残さない）。selector は「前回まで」の履歴を読むので、自回の
  追記は selector より必ず後（confirm 時）でなければ自回を過去回として弾いてしまう。confirm
  経路を統一するため、pending 化時に episode_key を `last_fetch.json` の `pending_episode` へ
  保存し、confirm 時にそれを引いて追記対象の回を特定する（`LastFetchStore#confirm!` /
  `#resolve_pending!` は確定した episode_key を返す）。新規 fetch を伴う publish は pending を
  経由しないので、その回の episode_key は `episode` から直接渡す。rollback! では
  pending_episode をクリアし、`restore!` では復元しない割り切り（復元したい場合は work/ に
  残る used ファイルから手動追記する）。

### Config

- `ai_agent.effort` は現状 `bin == "claude"` のときだけ `Internal::AiCli.run` が
  参照する。実装上対応しているのは claude のみだが、将来 effort に対応する別の
  AI CLI が増えたときに使い回す想定でこのフィールドを用意している。
- `Config.validate_publish_target!` は、mode 判定を通らずに公開先を触る CLI 操作
  （`--clean` / `--clean-archive`）のために独立して存在する。これを通さないと、
  生成物を作りきってからデプロイ段階で落ちる。`--ui-only` は `assets` も参照する
  ため `validate_publish_target!` ではなく `Config.validate_sections!` に
  `"cloudflare", "assets"` を直接渡す（後述「miyamai_news.rb」節参照）。
- `Config.validate_sections!` は `validate_for!`/`validate_publish_target!` が
  共通で使う検証本体（欠けているセクション名を集めて `MissingKeyError` にする）を
  公開したもの。mode の加算的な到達順序（`REQUIRED_SECTIONS_DELTA`）とは無関係に、
  個別の CLI 操作が実際に参照するセクションだけをその場で指定できる。
- `cloudflare` セクションは `pipeline.mode: publish` の必須セクション
  （`REQUIRED_SECTIONS_DELTA`）にも含める。publish は配信まで到達するため、
  配信先が未設定という状態で起動させない。
- R2 の S3 互換 API 認証情報（`R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`）と
  wrangler の認証（`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`）は
  config.yaml に置かず環境変数で渡す。config.yaml は「機密を持たないから git で
  追跡してよい」という前提で運用しているため、ここに秘密鍵を書くと前提が崩れる。
  `Internal::R2Storage` はこの環境変数の読み取りを実際に S3 クライアントを使う
  最初のリクエストまで遅らせる（`client` の遅延初期化）。インスタンス生成だけで
  必須化すると、公開先の情報を組み立てるだけで R2 に触らない経路（`object_exists?`
  を呼ばない `--clean` の対象外判定など）でも環境変数が無いと落ちてしまう。
- `cloudflare.episode_prefix` は `wrangler.jsonc` の `assets.run_worker_first` と
  揃える必要がある（片方だけ変えると mp3 が static assets 側にルーティングされ
  404 になる）。デフォルトは `episodes`。
- `Config.path=` は代入した時点で即座に新しいパスから読み直す設計。`miyamai_news.rb`
  の CLI 起動時検証（後述「CLI 起動時の config 検証」節参照）は、`--config` 指定時の
  読み込みエラーもまとめて拾えるよう、`Config.path=` の代入と検証呼び出しを同じ
  begin ブロック内に置いている。
- `AppConfig` は mode によってセクションの要否が変わるため、全セクションを任意属性
  （`attribute?`）にしている。必須判定はセクションの型の責務ではなく運用ルールなので
  `Config.validate_for!` 側で別途行う。
- `Voicepeak`/`Collect`/`Mixer` 等の `*_sec` 系属性が `Types::Coercible::Float` なのは、
  YAML に `1` のような整数表記のままでも通せるようにするため。
- `Base` が `transform_keys(&:to_sym)` するのは、YAML 由来の文字列キー Hash をそのまま
  構造体に渡せるようにするため。

### miyamai_news.rb（CLIエントリポイント）

- CLI 起動時の config 検証: `--ui-only`/`--clean`/`--clean-archive` は
  `pipeline.mode` とは無関係だが公開先（R2・Workers）を触るため個別に検証する
  （`--ui-only` は `assets` も参照するため `Config.validate_sections!("cloudflare",
  "assets")`、`--clean`/`--clean-archive` は `deploy_site` を呼ばないため
  `cloudflare` のみで足りる `Config.validate_publish_target!`。詳細は前掲
  「Publisher / Internal::Site」節参照）。`--confirm-fetch`/`--restore-fetch` は
  `work/last_fetch.json` のみを触り公開先も pipeline.mode も伴わないので検証を
  全てスキップする。それ以外は各コンポーネントが実行中に MissingKeyError で
  落ちて中途半端に失敗するのを避けるため、起動直後に必要な config が揃っているか
  一括で検証する（`Config.validate_for!`）。
- `--config` のパス解決は cwd 基準（一般的な CLI の期待動作。`__dir__` 基準だと
  スクリプト位置基準になり、リポジトリ外のディレクトリから相対パスを指定したときに
  意図と異なる場所を読んでしまう）。
- Gemfile で rss/csv/rexml を明示しているのは、これらが bundled gem のため
  明示しないと後続の `require` で読めないため。
- CLI フラグの解析（`parse_args`）と config 検証のみを担い、フラグに応じた工程の
  呼び分け自体は `Pipeline`（`lib/pipeline.rb`）に委譲する薄い層。

### Pipeline（工程オーケストレーション）

- `miyamai_news.rb` の CLI フラグに応じた工程の呼び分けと、その間の副作用
  （work/dist の mkdir・`Internal::EpisodeLogger` の configure）を一元管理する。
  新しいドメインロジックは持たず、既存の `ScriptGenerator`/`Publisher`/
  `LastFetchStore`/`Internal::EpisodeLogger` の呼び出し順序を集約するだけに徹する。
- `--clean`/`--clean-archive`/`--ui-only`/`--confirm-fetch`/`--restore-fetch` は
  Episode を作らない（`EpisodeLogger.configure` されないまま no-op で動く）という
  既存の不変条件があるため、`#run` はこれらを Episode 構築（`#setup_episode!`）より
  前で早期 return して処理する。
- `--publish-only` は新規収集を一切行わないため、フィードキャッシュを持つ
  `ScriptGenerator`（`FeedCache.new` が旧台帳ファイルを読む）を生成せず
  `#run_publish_only` を直接呼ぶ（`#setup_generator!` を経由しない）。
- `#run_script`（`--script-only`）は VOICEPEAK 向けの整形をしない、人間が読む
  台本までで停止する。台本の中身を確認・手直ししたうえで、フラグなしで
  再実行すれば既存の台本を再利用して整形〜音声合成〜publish まで続きから
  進められる（work_dir 内の中間ファイルの有無で再利用を判断する、前掲
  「ScriptGenerator / AI パイプライン」節の再利用機構に乗る）。
- `#run_clean_command` が呼ぶ `#clean_work_dir` は work/ の回ごとの中間ファイルを
  削除するが、回をまたいで保持する状態（`last_fetch.json` / `feed_cache/`
  ディレクトリ）はホワイトリスト方式の `work_globs` に含まれないので残る。消すと
  過去に見た記事を新着として拾い直し、重複紹介が起きるため。
- `#run_synthesize` が BGM パス（`assets.bgm_path`）を差し替え可能にしていないのは、
  `templates/index.html.erb` にクレジット表記（BGM 作者名）を固定で埋め込んでいるため。
  BGM を差し替えるとクレジット表記との整合が崩れる。
- `#ensure_mode_allows!` は、`--digest-only` は digest 相当、`--script-only`/
  `--synthesize-only` は synthesize 相当、`--publish-only` は publish 相当以上の
  config が検証されていないと実行できないようにする。満たさなければ、必要な config が
  未検証のまま実行が進んで途中で失敗するのを防ぐためここで止める。
- `#clean_published_dist` は、ストレージ上に同名オブジェクトが存在する（＝公開済みの）
  mp3 のみを削除する。未公開の回を誤って消さないための存在確認。
- `#setup_episode!` が `Episode.new` に渡す `now:` は `--date`/`--slot` の指定有無に
  関わらず常に `Time.now`（後掲「横断的な注意点」の `Episode#now` と
  `Episode#date`/`date_tag`/`slot` の独立性を参照）。
- 収集 window の pending 化（`LastFetchStore.mark_pending!`）は `Pipeline` 自身は
  呼ばない（前掲「LastFetchStore / 収集 window」参照）。

### 再生ページの JS（templates/index.html.erb）

- ネイティブの `<audio controls>` を廃し、再生/一時停止・シーク・音量・再生モードを
  自前で描画している（`renderPlay`/`renderTime`/`renderMute` 等）。
- `applyRelativeLabels` は `option` の `data-label`（元のラベル）を基準に毎回テキストを
  組み立て直す。差分更新ではなく毎回作り直すことで、繰り返し呼んでも
  「・3時間前・3時間前」のように相対時刻表示が積み上がらない（冪等）。
- `switchToArchive` で src を差し替えた直後にシークバー・時刻表示をいったん 0 に
  リセットするのは、新しい音源の duration が `loadedmetadata` 発火まで確定しないため。
- 再生モード `repeat` は `player.loop = true` を使うため、曲終端で `ended` イベント自体が
  発火しない。連続再生（`sequential`）の自動遷移ロジックは `ended` ハンドラにあるが、
  repeat 時はそもそもそこに来ない。
- 連続再生時の `player.play()` の reject を握り潰しているのは、ブラウザの自動再生
  ポリシーで reject されることがある一方、連続再生自体はユーザーが再生ボタンを押した
  操作の延長（自動再生ポリシーに抵触しない）なので、通常は起きない失敗として扱って
  よいため。

### 横断的な注意点

- `feed_parser.rb#normalize_link` と `feed_cache.rb` の同一性判定（link を
  identity key にする）は対になっている。末尾スラッシュの有無だけ違う同じ記事の
  URL を正規化してから identity key として使わないと、同じ記事を別記事として
  二重に扱ってしまう。`normalize_link` がスキーム直後の "//" を対象外にする負の
  先読みを使っているのは、"https://" 自体を末尾スラッシュ除去で壊さないため。
- `Episode#now`（収集基準時刻）と `Episode#date`/`date_tag`/`slot`（番組の日付・
  slot。ファイル名・ストレージのオブジェクト名・ログパス・Publisher のアーカイブ表示に使う）
  は独立した概念で、混同しないこと。`now` の消費者は `ScriptGenerator` 経由で
  `FeedCache`（`seen_at` 記録）・`LastFetchStore`（`since` 判定の起点）のみ。
  `Pipeline#setup_episode!` は `--date`/`--slot` 指定時に `date:`/`slot:` は明示上書き
  するが、`now:` には常に `Time.now`（実行時の実時刻）を渡す。`--date` で過去日を指定した際に
  `now` まで過去に飛ばすと、その実行で新規に見つかった記事の `seen_at` が過去時刻で
  記録され、`confirmed_at`（実時刻ベース）以下として `select_since_for` に弾かれる。
  `seen_at` は一度設定されると二度と更新されないため、これは一時的な欠落ではなく
  以後の全実行でその記事が恒久的に取りこぼされるデータ消失になる（過去回の作り直しは
  「日付・slot の見た目」だけを変える機能であり、収集基準時刻を過去に飛ばす必要はない）。
