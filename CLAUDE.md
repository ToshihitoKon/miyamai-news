# 宮舞モカの技術ニュース パイプライン

技術ニュースを RSS で収集し、台本生成 → 音声合成 → BGM 合成まで一貫して行い、
GCS 上の再生ページ（`index.html`）と Atom フィード（`feed.xml`）を更新するパイプライン。
詳細は README.md を参照。

## 本番環境の取り扱いに関する原則

このリポジトリは GCS バケットに公開読み取り可能なページ・フィードを配信しており、
不特定多数の読者・購読者が実際にアクセスしている。以下は検証目的であっても例外なく守る。

- **本番環境（特に `index.html`）が正常に動かなくなるおそれのある処理を行わない。**
  `index.html`・`feed.xml`・`manifest.json`・`archives.csv` など、公開バケットへの
  書き込みを伴う操作（`Publisher#run`/`#republish_ui`/`#clean_archive` や
  `gcloud storage cp/mv/rm` の直接実行）は、たとえ検証やデバッグ目的でも
  ダミーデータ・テストデータを本番バケットに反映させない。
  「後でロールバックできるから大丈夫」という判断はしない。ロールバックが完了する
  までの間、実際に読者がアクセスしうる時点でリスクは発生しており、可逆性は
  免罪符にならない。
- **新規 episode の publish 以外のタイミングで `feed.xml` を更新することはしない。**
  `feed.xml` の `<updated>` が動くと購読者に「新着」として通知される。
  UI 文言の修正や動作確認など、新しい回の公開を伴わない作業では
  `--ui-only`（`Publisher#republish_ui`）を使い、`feed.xml`・`archives.csv`・
  mp3 等の実ファイルには一切触れないこと。
- 新しく実装した「本番データに対して自動的に副作用を及ぼす機能」（保持件数超過分の
  自動隔離など）は、マージ・有効化した時点で次回の通常 publish 実行時に本番へ
  自動適用される。これを「一度きりの検証」だと軽く考えず、機能の初回本番適用として
  扱い、影響範囲（何件のエピソードが動くか等）を事前に本番データで確認してから
  進める。
- 本番環境で何かを確認する必要があるときは、以下の優先順位で安全な方法を選ぶ。
  1. 別環境（テスト用バケット・ステージング）を用意して検証する
  2. ロジックの単体テスト（`spec/`）・モックテストで代替できないか再検討する
  3. どうしても本番でしか確認できない場合は、読者に見える公開物を書き換える処理を
     コードレベルで無効化し、データ取得・判定ロジックのみをドライラン的に確認する
  4. 本番への書き込みを避けられない場合は、事前にユーザーへ影響範囲を説明し
     明示的な確認を得る

## パイプラインのドメイン知識・実装上の前提

本番安全性の原則（上記）とは別に、実装が前提としている業務ルール・外部ツールの癖・
ファイル間の不変条件をここにまとめる。コードコメントの整理に伴い、複数ファイル・
複数箇所に分散していた説明をここに集約した。コードを変更する際は、該当項目が
まだ成り立っているか確認すること。

### コメントの整理方針

ドメイン知識・不変条件・「なぜそうしたか」の背景は、コード内に書き散らさず**この節に
集約する**。コード側のコメントは簡潔に保ち、詳細な根拠は「（詳細は CLAUDE.md 参照）」の
ように参照で済ませる。同じ説明を複数ファイルに重複させない。

- コードから自明なこと（型・命名で分かること、逐条の処理説明）はコメントにしない。
- ある挙動の「なぜ」を説明したくなったら、まずこの節に該当項目があるか確認し、無ければ
  ここに追記してからコード側は参照にする。既にあるならコード側で繰り返さない。
- この方針で新規コード・既存コードのコメントを書く／整理する。

### Pipeline（工程オーケストレーション）

- `Pipeline`（`lib/pipeline.rb`）は `miyamai_news.rb` の CLI フラグに応じた工程の
  呼び分けと、その間の副作用（work/dist の mkdir・`Internal::EpisodeLogger` の
  configure・`LastFetchStore` の確定/pending化）を一元管理するオーケストレーター。
  新しいドメインロジックは持たず、既存の `ScriptGenerator`/`Publisher`/
  `LastFetchStore`/`Internal::EpisodeLogger` の呼び出し順序を集約するだけに徹する。
  `miyamai_news.rb` 自体は CLI 解析と `Pipeline` の呼び出しだけの薄い層になっている。
- `pipeline.mode`（digest/synthesize/publish、どこまで工程を進めるか）と、
  「配信先」（web/Slack/Discord、どこに出力するか）は別軸として扱う設計にしている。
  前者は `Config.mode`/`Config::MODE_ORDER` が担い、`Pipeline` はその到達段階に
  応じて `run_digest`/`run_synthesize`/`run_publish` を呼び分けるだけ。後者は
  `Config.notify.targets` と `Internal::Notifiers::NotifyDispatcher` が担う
  （詳細は次節「Notifier」参照）。配信先を増やしても、この到達段階のロジックに
  混ぜ込まない。
- `--clean`/`--clean-archive`/`--ui-only`/`--confirm-fetch`/`--restore-fetch` は
  Episode を作らない（＝ `EpisodeLogger.configure` されないまま no-op で動く）
  という既存の不変条件があるため、`Pipeline#run` はこれらを Episode 構築
  （`setup_episode!`）より前で早期 return して処理する。
- `--publish-only` は新規収集を一切行わないため、`ScriptGenerator`（コンストラクタが
  `FeedCache.new` 経由で旧台帳ファイルを読む実ファイルI/Oを伴う）を生成しない。
  `Pipeline#run` は Episode 構築を担う `setup_episode!` と、`ScriptGenerator` 構築を
  担う `setup_generator!` を分離しており、`publish_only` 経路は後者を呼ばない。

### Notifier（Slack/Discord digest 全文通知）

- **全文投稿の方針**: facts ファイル（`work/news_facts_<date_tag>_<slot>.txt`）の
  内容を要約・圧縮せず、構造（カテゴリ→記事→URL・要点要約）を保った全文を
  Slack/Discord へ投稿する。`Internal::FactsFullText`（`lib/internal/facts_full_text.rb`）
  はカテゴリ・記事の境界がどこかだけを判定し、記事の中身（URL・発行元・要点等）は
  見出し行から次の見出し直前までの生の行（raw_lines）としてそのまま保持する。
  フィールドに分解して後で再構成する設計は、再構成漏れによる情報欠落の恐れがあるため
  採用していない。パース失敗時（`## `見出しが無い等）は `ok: false` を返し、
  呼び出し側（各 Notifier）が生テキスト全体をチャンク分割して投稿するフォールバック
  経路を持つ。
- `Internal::FactsFullText` は `templates/extractor.prompt.erb` の出力フォーマットに
  依存する唯一のパーサ（`UsedNewsMarkdown` とは別物で、目的も文法も異なる）。
  `extractor.prompt.erb` の見出し・箇条書き構造を変更する際は
  `spec/internal/facts_full_text_spec.rb` の fixture ベーステストが通ることを確認する。
- **配信先の切り替えは CLI フラグを持たず、`config.yaml` の `notify.targets` のみ**
  で行う。`--digest-only` 実行時、facts ファイル生成後に `Pipeline#run_digest_only` が
  `Internal::Notifiers::NotifyDispatcher.run` を呼び、列挙された配信先だけを通知する。
  未設定（`targets` が空）なら何もしない。CLIフラグの組み合わせ爆発を避けるための
  単純さ優先の判断。
- **チャンク分割**: `Internal::Notifiers::Chunker`（`lib/internal/notifiers/chunker.rb`）
  が、プラットフォームごとの文字数上限に収まるようチャンクへ分割する。記事1本の
  内容が単体で上限を超えるケースがあるため、block（記事単位）の貪欲な詰め込みと、
  単体で上限を超える block の行単位・文字単位フォールバック分割の2段階で行う。
  戻り値のチャンクを連結すれば入力全体を復元できる（情報欠落なしの保証）。
  文字数は `String#length`（コードポイント数）で数える。`bytesize` で数えると
  日本語部分が想定より早く上限に達し、意図せず過剰分割されるため。
- **失敗時の扱い**: `Internal::Notifiers::NotifyDispatcher.run` は facts ファイル
  不在・config 欠落時に warn してその配信先だけスキップする（abort しない）。
  1ターゲットの想定外クラッシュも rescue して warn し、他ターゲットの投稿を
  道連れにしない。`Publisher#run` の即abortパターンとは異なる方針を採る理由は、
  Slack/Discord への通知が GCS 公開のような共有状態（archives.csv・feed.xml・
  last_fetch.json）を一切変更しないため。
- `notify` セクションは `Config::REQUIRED_SECTIONS_DELTA` に加えない。
  `pipeline.mode` の到達段階とは無関係なオプトイン機能であり、未設定でも他の
  機能に影響しないため。

#### Slack

- **incoming webhook ではなく Slack Web API（bot token + channel ID）を使う**。
  incoming webhook は URL のみで設定できるが、投稿しても `ts`（メッセージの
  タイムスタンプ識別子）を返さずスレッド返信ができない。`chat.postMessage` の
  戻り値 `ts` を次の投稿の `thread_ts` に指定することでスレッド化するため、
  bot token + channel ID を config（`notify.slack.bot_token`/`notify.slack.channel`）
  に持たせる設計にした。
- **投稿シーケンス**: `Internal::Notifiers::SlackNotifier` が親メッセージ
  （概要＋カテゴリ・記事タイトル一覧のみ、全文はここに含めない）を投稿し `ts` を
  得る。親メッセージが失敗したら `ts` が無いためスレッド返信は一切行わず warn して
  終了する。成功したらカテゴリごとに `Internal::Notifiers::Chunker` で全文を
  チャンク分割し、同じ `thread_ts` を指定してスレッド返信する。1通の失敗は warn
  して残りのカテゴリ・チャンクの投稿を継続する（即abortしない）。
- `Internal::Notifiers::SlackClient`（`lib/internal/notifiers/slack_client.rb`）は
  `chat.postMessage` への POST 専用クライアント。既存の `Internal::HttpFetcher` は
  GET専用のfetch実装で認証ヘッダーの概念を持たないため流用せず新規実装した。
  `HttpFetcher` と異なり、失敗しても例外を投げず常に `Response`（`ok`/`ts`/`error`）
  を返す。呼び出し元（`SlackNotifier`）が `ts` の有無で成否を判断し、warn して
  処理を継続できるようにするため。`Internal::EpisodeLogger` には成否・所要時間の
  みを記録し、bot_token・channel・投稿本文はログに残さない。

#### Discord

- **スレッド概念を使わず、webhook URL への複数メッセージ連続 POST で全文相当を
  投稿する**。Slack と異なり、Discord は webhook のレスポンスが成功時 204 no
  content で後続投稿に使う識別子（Slackの`ts`に相当するもの）を持たないため、
  スレッド化・親子関係の構築はそもそも成立しない。全文をカテゴリ・記事単位の
  block として並べ、`Internal::Notifiers::Chunker` で 2000文字（`CONTENT_LIMIT`、
  Discord API のハード制約）以内のチャンクに分割し、順に webhook へ POST する。
- `Internal::Notifiers::DiscordClient`（`lib/internal/notifiers/discord_client.rb`）は
  webhook への POST 専用クライアント。認証ヘッダーは不要（webhook URL 自体が
  秘匿情報）。成功可否のみ true/false で返す（Slackの`Response`のような戻り値型は
  不要。後続投稿に使う識別子が無いため）。`Internal::EpisodeLogger` には成否・
  ステータスコード・所要時間のみを記録し、webhook URL・投稿本文はログに残さない。
- 1通の投稿が失敗しても warn して残りのチャンクの投稿を継続する（Slackと同じ
  warn-and-continue の方針。即abortしない）。

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
- extra フィールド（はてブのブックマーク数など）は、書き込み時はシンボルキーだが
  JSON 往復後は常に文字列キーになる。extra を読む側（hatena_bookmarks.rb 等）は
  文字列キー前提で書くこと。
- 最終 fetch から `collect.fetch_skip_minutes`（既定5分）以内は HTTP を叩かず、前回
  キャッシュから同じ結果を返す（スキップ時は seen_at / last_fetched_at / fetched_at を
  一切更新しない完全な read no-op。fetched_at を更新すると skip_window ごとの再実行で
  永久にスキップし続けてしまう）。スキップは HTTP を叩かない＝FetchError も起きないので、
  一部フィードが一時的に落ちていても短時間の再実行なら先へ進める。0 で無効。
- FeedCache#fetch は複数スレッドから同時に呼んでよい。フィードごとに別ファイルなので
  キャッシュ更新の直列化（Mutex）は不要（同一 URL を 2 スレッドが同時に触らない前提。
  ScriptGenerator が 1 フィード 1 ジョブで並列に呼ぶ）。書き込みは tmp→rename で atomic。
- entry の同一性キーは正規化した link（末尾スラッシュの有無を無視）。キャッシュファイル名
  も正規化した URL の SHA1 で、いずれも feed_parser.rb#normalize_link を通す。正規化前の
  URL をそのまま identity にすると同じ記事を別記事として扱ってしまう。

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
- MAX_CHARS=140 は VOICEPEAK の 1 回の合成呼び出しあたりの文字数上限（ハード制約）。
- 話題転換タグ `[interval:mid]` / `[interval:long]` は、文分割・MAX_CHARS 分割より
  **先に**検出・除去すること。後で分割するとタグ文字列自体が分割で壊れる恐れがある。
- `voice_{date}_{slot}.mp3` は合成結果のキャッシュとして機能する。存在すれば
  VOICEPEAK を起動せず再利用する（`--synthesize-only` でブースト値だけ調整したい
  場合など）。
- `wav_{date}_{slot}/` ディレクトリが残っている場合、前回の合成が途中でクラッシュ
  した痕跡。完全成功時のみ削除されるので、残っているチャンクを再利用して続きから
  再開できる。
- 無音秒数の設定値が 0 以下の場合、その pause 種類はハッシュのキー自体を持たない
  （0 秒のファイルを作るのではなく、キー省略により `concat_to_mp3` が `Hash#[]`
  の nil で無音挿入をスキップする）。
- 直後に文が続かない話題転換タグ（連続するタグなど）は、その pause 指定ごと
  静かに捨てられる（低頻度の許容済みエッジケース）。

### Publisher / GCS（公開先の運用ルール）

- GCS のオブジェクト名は渡された mp3 ファイル名をそのまま使うこと。日付から
  組み立て直すと slot（朝/昼/夜/深夜）が落ち、同日複数回のエピソードが同名衝突して
  上書きし合う。
- `object_exists?` は「オブジェクトが存在しない」と「確認自体に失敗した」を
  区別する。`gcloud storage ls` は「オブジェクトが無い」場合も他の失敗
  （認証切れ・ネットワーク障害等）の場合も exit code 1 を返すため、メッセージ内容
  で判定する。判定不能な失敗を「存在しない」扱いにすると、archives.csv を
  「初回で台帳が無い」と誤認し、既存台帳を新規 1 行で上書きして過去エピソード
  全履歴を消失させかねない。
- `archived/` への退避は publish 時に自動で行われるが、実削除はされない。実削除は
  `Publisher#clean_archive` を明示的に呼んだときだけ行われる。
- `Publisher#run` 中に `gcloud storage` 操作が 1 つでも失敗したら即 abort する。
  公開バケットが index.html/feed.xml/manifest.json/archives.csv/mp3 の間で
  中途半端に不整合な状態のまま残らないようにするため。
- `Publisher#run` は GCS への書き込みを一切始める前に
  `UsedNewsFormatter.ensure_valid!` で used_news のフォーマットを確定させる
  （前掲「used_news の表示フォーマット」節参照）。検証・修復に失敗すればここで
  abort し、mp3 を含め何もアップロードしない。「Publisher#run 中に 1 つでも
  失敗したら即 abort する」という上記原則の一部として扱う。
- `.used.html`（used_news を事前に HTML 化したもの）は `dist/` に実体を持たない
  GCS 専用の派生物であり、`EPISODE_FILE_EXTENSIONS`（`.mp3`/`.used.txt`/
  `.transcript.txt` の3つ固定）には含めない。`archive_episode_files` では
  `.used.html` の退避を個別に fault-tolerant に行う（無ければ mv 失敗を警告に
  留めて継続する既存パターンを踏襲）。
- Atom entry の `<id>` はエピソードごとの mp3 URL のままにすること（index.html に
  しない）。`<id>` は RSS リーダー側の新着重複判定キーであり、全エントリを同じ id
  にすると購読者が新着を検知できなくなる。
- `cover_image` / `icon_image` は本パイプラインからはアップロードしない。事前に
  手動で GCS バケットへアップロードしておく必要がある（README 参照）。
- 既に公開済みの slot（同じ mp3 ファイル名）に対して再度 publish すると
  `updated_at` が進み `<updated>` が動いてしまう。**これは避けるべき運用**であり、
  UI 文言の修正など新しい回の公開を伴わない変更では必ず `--ui-only`
  （`republish_ui`）を使うこと（「新規 episode の publish 以外のタイミングで
  feed.xml を更新しない」という原則を、既存 slot への誤った再 publish でも
  破らないように徹底する）。

### LastFetchStore / 収集 window（last_fetch.json）

- 収集 window（confirmed_at）は実行が完了しただけでは進まない。人間が成果物
  （facts/台本/mp3）を確認し「進めてよい」と判断した時点で初めて確定する。
  publish だけは公開自体が確定行為なので例外（`confirm_immediately!` で即時確定）。
- `resolve_pending!` の確認プロンプトで無回答（Enter/N）の既定はロールバック
  （＝ confirmed_at を進めない）。理由: 記事を取りこぼす（confirmed_at を進めて
  しまうと二度と収集対象に戻らない）よりも、次回また同じ記事が候補に上がる
  （重複・再確認の手間）方が安全という判断。

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
- ニュースの重複除去はタイトル基準（大文字小文字・空白を無視）。
- `fetched_news?` は「この実行で一度でも新規 RSS 収集が発生したか」を表す
  フラグで、呼び出し側（miyamai_news.rb）が収集 window を pending 化すべきか
  判断するのに使う。digest→generate と同一インスタンスで複数回工程を呼んでも、
  一度 true になったら false に戻らない。
- writer ステップ（台本執筆）は、既に抽出済みの facts シートに基づいて執筆させる
  よう**プロンプト側**で指示している（Web への再アクセスによる手戻り・情報の
  食い違いを防ぐため）。`allowedTools` は全 AI CLI 呼び出しで共通の
  `"Read Write WebFetch"` に固定しており（`Internal::AiCli.run` 参照）、
  呼び出し元ごとにツールを絞ってはいない（実害のあるツールではなく、
  用途ごとに出し分ける利点が薄いため）。
- `category_details` は「AI への執筆方針の指示」と「used_news のカテゴリ見出し
  （`## ラベル名`）として使う正式なラベル一覧」を兼ねる。`UsedNewsFormatter.strip_preamble`
  （`ScriptGenerator` ではなく `UsedNewsFormatter` 側にある。前掲「used_news の
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

- **Config と同じモジュールレベルのグローバル状態**。`miyamai_news.rb` の
  `main` 内で episode 確定後・`WORK_DIR` 作成後に一度だけ `configure(path)` する。
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
- `work_globs(work_dir)` は `work/*.log` を返し、`miyamai_news.rb` の
  `clean_work_dir` が他コンポーネントの `work_globs` と合算して `--clean` の
  対象にする（`ScriptGenerator`/`VoiceSynthesizer` と同じホワイトリスト方式）。

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
`UsedNewsMarkdown.render` で used_news を HTML 化し、`.used.html` として GCS へ
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
  独立 URL 行）は `ok=false` になり、GCS 上にも `.used.html` は存在しない
  （今回の変更以降に publish された回でしか生成されない）。JS の 404 フォールバックが
  これを吸収し、GCS に残る過去回は壊れず従来どおり表示される。

#### フォーマット保証は Publisher の責務（ScriptGenerator ではない）

used_news のフォーマットが厳密に正しいかどうかを検証・保証する責務は
**`ScriptGenerator` ではなく `UsedNewsFormatter`**（`lib/internal/used_news_formatter.rb`）
にあり、**Publisher が GCS への書き込みを始める前に呼ぶ**（`UsedNewsFormatter.ensure_valid!`）。

- `ScriptGenerator` は「## カテゴリ / ### [タイトル](URL)」形式のそれっぽい
  Markdown を生成するだけで、前置き除去も含めてフォーマットには一切手を入れない
  （work/ の中間ファイルには AI が書いた生のテキストがそのまま残る）。
- `UsedNewsFormatter.ensure_valid!(text)` は、前置き除去 → `UsedNewsMarkdown.render`
  で検証 → 崩れていれば軽量モデルで修復、の順に整えて返す。修復後もフォーマットが
  直らなければ **`abort` し、`Publisher#run` 全体を止める**（GCS への書き込みは何も
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
  直接的に表す。

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
- used_news を書く工程は 2 つある。extractor が facts と一緒に**暫定版**を書き
  （`templates/extractor.prompt.erb`。digest mode の到達点でも履歴の元データを残すため。
  候補として facts 化した全ニュースが対象）、writer 到達時に**同じパス**へ**確定版**
  （`templates/writer.prompt.erb`。台本で実際に紹介したもの）を上書きする。confirm 時に存在
  する方が履歴に入る。これにより digest mode 運用でも履歴が溜まる（used_news が全く無い
  digest なら記録するものが無く、`record!` は `File.exist?` ガードでスキップする）。暫定 used は
  履歴用の副産物なので、extractor が書き損ねても digest は止めない（`finalize_optional_used_news`
  は無ければ何もしない）。確定 used を書く writer 側はファイル欠落なら従来どおり abort する
  （不完全なまま後段へ進ませない）。フォーマット検証・AI 修復は行わない（前掲「used_news の
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
  AI CLI が増えたときに使い回す
  想定でこのフィールドを用意している。
- `Config.validate_gcs!` は `pipeline.mode` に関わらず GCS を使う CLI 操作
  （`--clean` / `--ui-only` / `--clean-archive`）のために独立して存在する。
  mode 別の `validate_for!` では拾えない gcs セクション単体の欠落をここで検出する。

### 横断的な注意点

- `feed_parser.rb#normalize_link` と `feed_cache.rb` の同一性判定（link を
  identity key にする）は対になっている。末尾スラッシュの有無だけ違う同じ記事の
  URL を正規化してから identity key として使わないと、同じ記事を別記事として
  二重に扱ってしまう。
