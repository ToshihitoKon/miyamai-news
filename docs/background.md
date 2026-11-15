# パイプラインのドメイン知識・実装上の前提

本番安全性の原則（CLAUDE.md 参照）とは別に、実装が前提としている業務ルール・外部ツールの癖・
ファイル間の不変条件をここにまとめる。コードを変更する際は、該当項目がまだ成り立っているか
確認すること。

コード側にはこのファイルへの参照コメントも含め、WHY・背景説明のコメントは一切書かない
（詳細は CLAUDE.md「コメントの整理方針」節参照）。ある挙動の「なぜ」を説明したくなったら、
まずこのファイルに該当項目があるか確認し、無ければここに追記する。

書くのは「なぜそうしているか」と、それを支える不変条件だけにする。次のものは書かない。

- 外部ツール（agy・VOICEPEAK・Cloudflare 等）の版で変わる細部（終了コード、エラー文言、
  ログに出る行、版番号、数値の上限）
- 実験や障害の経緯（いつ何を試したか）。判断とその理由の一文に縮める
- コードやコードの命名から読み取れること

旧形式のデータを読むための互換処理は、末尾の「移行互換」節にまとめる。旧データが
残っていないことを確かめたら、コードごと消す。

## コンポーネント別の前提

### FeedCache（フィード収集・重複判定）

- 新着判定は掲載日時ではなく seen_at（このキャッシュが entry を初めて見た時刻）を使う。
  はてなブックマーク・Qiita のようなキュレーション系フィードは、昔書かれた記事が
  今になって話題化して再度載ることがあるため。
- パージ（キャッシュからの削除）は last_fetched_at（直近でそのフィードに実際に
  見えていたか）基準で行う。seen_at 基準にすると、過去記事をフィードに載せ続ける
  ソースで、記事がキャッシュから消えた後に「未知の entry」として再登場し二重紹介につながる。
- キャッシュはフィード URL ごとに 1 ファイル（`work/state/feed_cache/<正規化 link の SHA1>.json`）。
  同じ記事が複数フィードから流れてくる重複は FeedCache の関心事ではなく、
  収集後の dedup_by_title（タイトル基準）が扱う。
- 収集 window の since は排他的下限（seen_at > since）で判定する。同一実行由来の
  確定の収集時刻（`at`）と seen_at が一致することがあり、含めると同じ記事を毎回新着として
  二重紹介してしまう。
- extra フィールド（はてブのブックマーク数など）は、書き込み時はシンボルキーだが
  JSON 往復後は常に文字列キーになる。extra を読む側は文字列キー前提で書くこと。
- 最終 fetch から `collect.fetch_skip_minutes` 以内は HTTP を叩かず、前回キャッシュから
  同じ結果を返す。スキップ時は seen_at / last_fetched_at / fetched_at を一切更新しない
  （fetched_at を更新すると再実行のたびに永久にスキップし続ける）。
  スキップ時に返す link は、直前の実 fetch に載っていたもの（`last_fetched_at` が
  `fetched_at` と一致する entry）だけに絞る。purge は実 fetch 時にしか走らないため、
  全件を返すとフィードから落ちた古い記事がスキップ経路でだけ候補に復活する。
- FeedCache#fetch は複数スレッドから同時に呼んでよい。フィードごとに別ファイルで、
  同一 URL を 2 スレッドが同時に触らない前提（ScriptGenerator が 1 フィード 1 ジョブで
  並列に呼ぶ）。書き込みは tmp→rename で atomic にする。
- entry の同一性キーとキャッシュファイル名は、feed_parser.rb#normalize_link で正規化した
  link（末尾スラッシュの有無を無視）。正規化しないと同じ記事を別記事として扱ってしまう。
- `load_cache` は、キャッシュファイルが valid JSON だが Hash でない壊れ方をしていた場合、
  空扱いにせず abort する。空扱いにすると、そのフィードの全 entry が新着として再流入し、
  二重紹介を招くため。
- フィード本文のパースは HttpFetcher のリトライの外で行うため、失敗したら即 `FetchError` に
  し、取得失敗と同じくそのソースをこの回は飛ばす。

### HatenaBookmarks（はてなブックマーク RSS 固有の知識）

- `rss` gem ははてなブックマーク RSS(RDF) の hatena 名前空間の要素（ブックマーク数等）を
  公開しないため、REXML で直接パースしてブックマーク数を取り出す。
- `count_of(extra)` は、はてブ以外のソース由来の entry では 0 を返す。他ソースに
  ブックマーク数欄が無いのは異常ではないため。

### Arxiv（arXiv フィード固有の知識・投稿年月フィルタ）

- arXiv のカテゴリ別 RSS は、新規投稿（`Announce Type: new`）だけでなく、他カテゴリへの
  追加（`cross`）や改訂（`replace`）も含む。`replace` はフィードの日付が改訂日を指すため、
  何年も前の論文が毎回再登場する。`FeedCache` の新着判定では弾けないため、
  `ScriptGenerator#collect_source` 側で `Internal::Arxiv.old?` による足切りを行う。
- `Announce Type` ではなく arXiv ID の YYMM（投稿年月）で足切りする。`new` の ID は常に
  当月のため `Announce Type` は判定材料にならず、古い論文はほぼ `replace` から来るため。
  ID は投稿月までしか分からないので、`old?` はその月の最終日を投稿日とみなす
  （同月内の記事を誤って古い判定にしないための安全側の丸め）。
- `max_age_days` は `RssFeedSource` の任意属性で、設定したフィードだけ判定が働く。

### GithubReleases（GitHub Releases フィード固有の知識）

- GitHub Releases の Atom フィードは、entry のタイトルがリリース名だけで、多くの
  リポジトリではバージョン番号しか入らない。そのままでは再生ページの「紹介したニュース」欄で
  どのツールの更新か分からず、`dedup_by_title` が同じ番号の別リポジトリのリリースを
  重複とみなして落とす。そのため `ScriptGenerator#collect_source` で、リンクが
  リリースページ（`/releases/tag/`）の entry に限り、タイトルの先頭にリポジトリ名を付ける。
- 付ける名前は config の `name` ではなく、リンクから取れるリポジトリ名にする。config の
  書き方に左右されず、リンクだけで機械的に決まるため。
- 変換は FeedParser・FeedCache ではなく収集後の `collect_source` で行い、キャッシュには
  フィードの元のタイトルを残す。FeedParser はフィード提供元固有の知識を持たない方針のため。

### HttpFetcher（単一 URL の取得）

- `MAX_REDIRECTS` はリダイレクト追従の上限ホップ数。無限リダイレクトループによる
  永久ハングを防ぐための安全弁。
- 5xx・429・通信層の例外（タイムアウト・接続リセット・名前解決失敗・TLS 失敗・途中で
  切れた gzip 本文など）は指数バックオフでリトライする。429 以外の 4xx とリダイレクト異常は、
  再送しても結果が変わらないため即座に失敗させる。
- 通信層の例外は、一時的なものと恒久的なもの（ドメイン失効、証明書の検証失敗等）を
  例外クラスで区別できないため、まとめてリトライ対象にする。代償として、恒久的に失敗する
  フィードは締め切りまで 1 スレッドを占有する。
- `StandardError` 全般をリトライ対象にすると、プログラムの不具合でも締め切りまで
  待ち続けるため、リトライ対象は `RETRYABLE_ERRORS` に列挙したものに絞る。
- リトライは回数ではなく締め切り時刻（`retry_deadline`）で打ち切り、締め切りは収集開始時に
  1 つだけ決めて全フィードで共有する。フィードごとに数えると、収集フェーズが
  `collect.fetch_retry_timeout_sec` の数倍に伸びるため。
- 締め切り後に再試行は始めないが、最初の試行は締め切り後でも行う。締め切り後に順番が
  回ってきた正常なフィードを取りこぼさないため。
- 最後の試行そのものは締め切りを越えて続きうるので、収集フェーズは締め切りより長くなる
  ことがある。Net::HTTP の既定のタイムアウトだと応答しないフィード 1 つがスレッドを
  長く占有するため、`REQUEST_TIMEOUT_SEC` で短く明示している。
- 1 回の待機を `collect.fetch_retry_max_interval_sec` で頭打ちにする。倍々に伸ばし続けると
  締め切りまでの試行回数が減るため。
- `Retry-After` ヘッダーは解釈しない。長い `Retry-After` を返されると、締め切りまで
  再試行を続けてからそのソースを飛ばす。
- `Location` ヘッダーは相対 URI のことがあるため、直前の URL を基点に `URI#merge` で解決する。
- `USER_AGENT` を明示するのは、Net::HTTP のデフォルト UA（`"Ruby"`）に 403 を返す
  サイト（dev.to など）があるため。

### TemplateRenderer（ERB テンプレート描画）

- `render` は渡された context オブジェクトの binding で ERB を評価する。テンプレート
  側から context のインスタンス変数や private メソッド（`h` 等）をそのまま呼べるのは
  このため。テンプレート固有の値は `locals` ハッシュで明示的に渡す。
- `trim_mode: "-"` は `<%- -%>` を書いたときだけ前後の空白を削る。通常の `<%= %>` には
  影響しないため、プロンプト用と HTML/XML 用のテンプレートを同じ設定で扱える。

### CommandError（外部コマンドのエラーメッセージ整形）

- `tail` が長さチェックを挟んでいるのは、短い stderr で `err[-max_chars..]` が `nil` になり、
  失敗理由が丸ごと消えるのを防ぐため。

### AudioMixer（BGM 合成）

- `voice_boost_db` は VOICEPEAK の出力音量が小さめなため底上げするゲイン。
- ffmpeg に `-stream_loop -1` を指定するのは、BGM がナレーションより短くても途切れない
  ようループさせるため。`amix` に `normalize=0` を渡すのは、指定した音量バランスを
  そのまま保つため。
- `probe_duration` が `Float()` で厳格パースしているのは、ffprobe が成功終了でも `N/A` を
  出力することがあるため。`"N/A".to_f` は黙って `0.0` になり、誤った値が後段に伝播する。

### Slot（番組の時間帯区分）

- 1 日に複数回番組をまわしても回ごとに別の slot を持たせ、ファイル名を衝突させず
  別エピソードとして共存させるための区分。
- `sort_key` は未知の slot を例外にする。ソート順が壊れたまま気づかずに進行しないように。

### VoiceSynthesizer / VOICEPEAK（外部 GUI アプリの癖）

- VOICEPEAK は本来 GUI アプリで、間髪入れず連続起動すると初期化中にクラッシュする
  ことがある。各合成後に interval_sec だけ間隔を空け、失敗時は指数バックオフでリトライする。
- 異常終了後もプロセスが応答を返さず永久にハングすることがある。timeout_sec を
  超えたらハングとみなし、プロセスグループごと TERM→KILL の順で kill する。
- **子プロセスの stdout/stderr は `Process#join` の前に別スレッドで読み進めておくこと。**
  読まずに join を待つと、出力が OS のパイプバッファを超えた時点で子プロセスの write が
  ブロックし、正常動作中でも timeout_sec 超過の「偽ハング」と誤判定する。
- VOICEPEAK は空白（全角・半角）を間として認識せず、前後の語をそのまま繋げて
  読み上げる。読点「、」なら間を取る。そのため format.prompt.erb では空白を残さず読点に
  置き換えるか詰めるルールにしている。
- `MAX_CHARS` は VOICEPEAK の 1 回の合成呼び出しあたりの文字数上限に合わせている。
- 話題転換タグ `[interval:mid]` / `[interval:long]` は、文分割・`MAX_CHARS` 分割より
  **先に**検出・除去すること。後で分割するとタグ文字列自体が分割で壊れる恐れがある。
- `voice_{date}_{slot}.mp3` は合成結果のキャッシュとして機能する。存在すれば
  VOICEPEAK を起動せず再利用する（ブースト値だけ調整したい場合など）。
- `wav_{date}_{slot}/` ディレクトリが残っている場合、前回の合成が途中でクラッシュ
  した痕跡。完全成功時のみ削除されるので、残っているチャンクを再利用して続きから
  再開できる。
- wav チャンクのファイル名は `<index>_<textのSHA256先頭8桁>.wav`。index だけで
  照合すると、`tts_script_*.txt` を編集して再実行したときに旧スクリプト由来の wav を
  再利用し、編集前後の文が混在した音声が無警告で生成される。
- `Process.getpgid` が `Errno::ESRCH` を投げた場合（起動直後のクラッシュ）は
  `SynthesisError` に正規化し、通常のリトライに乗せる。
- 直後に文が続かない話題転換タグ（連続するタグなど）は、その pause 指定ごと
  静かに捨てられる（低頻度の許容済みエッジケース）。
- 失敗や中断で途中まで書かれた wav が残ると、次の再開や読み間違いチェックで壊れた音声が
  使われる。そこで `run_voicepeak` は、成功しないまま抜けるとき（失敗・タイムアウト・中断）に
  プロセスグループを止めてから出力先を消す。VOICEPEAK は `pgroup: true` で別のプロセス
  グループにいるため Ctrl-C が届かず、止めずに消すと残った VOICEPEAK が後から書き直す。
  - プロセスグループを止めるのはこの ensure の 1 か所だけにする。2 回止めに行くと、macOS では
    ゾンビだけになったグループへの kill が `Errno::EPERM` を返し、`SynthesisError` を
    置き換えて合成全体が落ちる。同じ理由で `kill_process_group` は `ESRCH` と `EPERM` を
    「既に終了済み」として扱う。
  - 後始末は `Thread.handle_interrupt` の中で行い、その間の 2 回目の Ctrl-C は遅らせる。
    TERM と KILL の間に割り込まれると、消したはずの出力先を VOICEPEAK が書き直すため。
  - 空のファイルは失敗として扱い、合成済みとして使い回すのも中身のあるファイルだけにする
    （Ruby ごと SIGKILL されて後始末が走らなかった場合に備える）。
  - 一時ファイル名に書かせて成功時に rename する方法は採らない。VOICEPEAK に渡す出力名を
    変えると、VOICEPEAK がその名前をどう扱うかを実機で確かめ直す必要があるため。
- VOICEPEAK の失敗は `VoiceSynthesizer::SynthesisError` で表し、リトライと呼び出し側の中断はこの型だけを
  拾う。`RuntimeError` 全体を拾うと、コードの不具合まで「合成の失敗」としてリトライや再実行の案内に
  回ってしまうため。

### TtsReadingCheck（VOICEPEAK 読み間違いチェック）

tts_script を VOICEPEAK で合成し直し、agy に wav をひらがなへ書き起こさせ、台本と突き合わせた
読み間違いの疑いを `tts_report.md` に出す（`scripts/check_tts_reading.rb`）。

- 配信のパイプラインから呼ばない手動のチェックなので、このツールだけが使うロジックとプロンプトは
  `scripts/lib/` に置き、`lib/` にはほかの処理と共有する部品（`VoiceSynthesizer` の wav 合成、
  `Internal::RestrictedAgy`）だけを置く。`lib/pipeline.rb` は `clean` で作業ファイルを消すための
  glob（`work/tts_check_*`）だけを持ち、ツールを require しない。

#### agy に読ませるもの

- 書き起こしの agy 呼び出しには台本の本文を渡さない。台本を見せると、書き起こしが正しい読みに
  引っ張られて、VOICEPEAK の読み間違いが出力から消えてしまうため、聞こえた音だけを書かせる。
- 書き起こしの agy が読める wav ディレクトリ（`work/tts_check_<key>/`）には wav 以外を置かない。
  正解の文を書いたテキストがあると、agy は音声ではなくそれを読みに行くため。台本の本文・
  書き起こし・判定の出力は、ディレクトリの外（`work/tts_check_<key>.*`）に置く。合成の後には、
  使われなくなった古い wav も `.DS_Store` などの wav 以外のファイルも消す。
- agy には `--dangerously-skip-permissions` を付けず、`--settings` で `read_file(<wav ディレクトリ>/*)`
  だけを許可する。全ツールを自動承認すると、agy は書き起こしではなく正解の文探し（ホーム全体の
  検索など）に向かい、出力なしで終わるため。`--settings` の許可リストはグローバル設定と
  マージされず置き換わる前提で、判定の呼び出しで許可リストを空にする設計もこれに依存する。
- `<key>` は台本のファイル名から作るが、英数字と `_` `.` `-` 以外は `_` に置き換え、置き換えが起きた
  ときは元の名前の SHA256 の先頭 8 桁を付ける。wav ディレクトリのパスは許可規則にそのまま入るため、
  括弧や空白が入ると規則が壊れ、wav の読み込みがすべて拒否されて原因の分からない失敗になる。
  ハッシュを付けるのは、置き換えで別の台本と同じ key にならないようにするため。
- wav ディレクトリのパス全体（リポジトリの場所を含む）が英数字と `_` `.` `/` `-` だけでできていなければ、
  合成の前に止める。`Internal::RestrictedAgy` も、規則に入れられないパスでは agy を起動せずにエラーにする。
- agy は出力なしでも成功終了しうるため、`Internal::RestrictedAgy` は stdout が空なら失敗とみなす。
  空かどうかは不正なバイトを置き換えた写しで判定する（そのまま `strip` すると例外で落ちるため）。
- 実行ログ（`work/tts_check_<key>.log`）には agy と VOICEPEAK の stdout・stderr を残し、
  プロンプトは含めない。
- 書き起こしと判定は agy の `--settings` でツールを絞るため、agy でしか動かない。`ai_agent.bin` が
  agy（パスならファイル名が agy）でなければ合成の前に止める。起動するのも `ai_agent.bin` に書いた
  バイナリにして、確かめたものと動かすものをそろえる。
- 判定には台本の本文が要り、書き起こしには台本を見せられないため、agy の呼び出しを書き起こしと
  判定の 2 回に分ける。判定の呼び出しは許可リストを空にして、ツールを 1 つも使えなくする。

#### 書き起こしの分割と使い回し

- 書き起こしは `TRANSCRIBE_BATCH_SIZE` 個ずつのまとまりに分け、まとまりごとに agy を呼ぶ。
  1 回に多く読ませると、agy が途中で文脈を要約して wav の数を誤り、失敗するため。値は、
  要約が起きた個数より十分小さくなるように選んでいる。
- まとまり同士は保存先も照合も別々で順番に依存しないため、まとまりごとの agy は同時に呼ぶ。
  同時に呼ぶ数に上限は設けない（1 回分の台本でまとまりは 6 個前後に収まるため）。
- どれかのまとまりが失敗しても、他のまとまりは最後まで走らせて保存してから、失敗したまとまりを
  まとめて報告して止める。途中で止めると、走っている他のまとまりの agy に払ったトークンが
  保存されずに無駄になるため。
- 書き起こしは高いので、まとまりごとに agy の出力をそのまま `work/tts_check_<key>.transcribe.<n>.txt` に
  保存し、書き起こしの入力（`ai_agent.model`、テンプレート原文の SHA256、各 wav の中身の SHA256）を
  書いた `.transcribe.<n>.inputs.txt` と組にする。入力がすべて一致する間は再実行でも使い回し、
  変わったまとまりだけを取り直す。テンプレートは描画後ではなく原文のハッシュを取る（描画後は
  wav の絶対パスを含み、リポジトリの場所を変えただけで取り直しになるため）。
- 照合を wav の名前ではなく中身で行うのは、音声が変わったとき新しい音声と古い書き起こしが黙って
  組になるのを防ぐため。モデルとプロンプトも照合に入れるのは、変える前の書き起こしが黙って
  使い回されないようにするため。
- 保存では、照合用の入力のファイルを先に消してから出力、入力の順に書く。途中で止まっても、
  新しい出力と古い入力が組にならない。
- agy で取り直した出力を保存する前に、それまでの出力が読み取れて入力のファイルもそろっていれば、
  `.transcribe.<n>.previous.txt` と `.previous.inputs.txt` に移す。取り直しの結果が使えないと、
  トークンをかけた前回の書き起こしが上書きで失われるため。読み取れない出力は移さないので、
  `previous` には最後に使えた書き起こしが残る。
- 保存するのは生の出力だけで、読み取った結果は保存しない。手で直した出力が、保存済みの読み取り
  結果に負けて黙って無視されないようにするため。
- agy の出力が読み取れなければ、そのまとまりだけを 1 回だけ自動で取り直し、それでも読み取れなければ
  止める。内容に問題がなくても断り文だけが返ることがあり、取り直すと通るため。1 回に限るのは、
  まとまり 1 つ分のトークンを何度も払わせないため。
- 保存済みの出力が入力と一致しても読み取れないときは、そのまとまりだけを取り直す。手で直した出力が
  読み取れれば、取り直さずに使う。
- `--resynthesize` は保存済みの wav を消して合成し直す（VOICEPEAK のユーザー辞書を変えたときなど、
  wav は名前が一致すれば合成し直さないため）。`--retranscribe` は wav を残したまま書き起こしだけを
  取り直す。書き起こしのやり直しで VOICEPEAK の合成時間を払わせないため、2 つを分ける。
  `--resynthesize` を付けた実行が合成の途中で失敗したときは、フラグを外して再実行するよう案内する
  （付けたままだと、途中まで作り直した wav をまた消して最初からになるため）。

#### 出力の読み取り

- 番号付きの行が 1 つもない出力は、出力の先頭部分（`EXCERPT_LENGTH` 文字）をエラーに載せる。
  断り文のような、書き起こしでない出力だとすぐ分かるようにするため。長さは、断り文の主旨が
  収まり、ターミナルで数行に収まる程度にしている。
- チャンクの本文に残る改行は、レポートの箇条書きと判定プロンプトでは空白に置き換えて 1 行に
  する（1 行 1 チャンクの形が崩れないように）。
- 読み取りは全角の数字・コロン、`1.`、箇条書きの印、番号の太字を許し、形式の揺れで取り直しの
  トークンを払わないようにする。同じ番号の行が 2 回以上出たときは、どちらが書き起こしか決められない
  ため、エラーにして生の出力を手で直させる。
- 番号付きの一覧が始まる前の行は前置きとして読み飛ばすが、一覧が始まった後に、チャンク数を超える番号の
  行や番号のない行（空行とコードフェンスを除く）が出たときはエラーにする。1 チャンクの書き起こしが
  2 行に割れると、エラーにならないまま書き起こしが別のチャンクに割り当てられ、偽の読み間違いが
  正誤表を埋めるため。
- 生の出力が UTF-8 として正しくないときも、読み取りのエラーとして手直しを案内する。そのまま落ちると、
  入力が一致したままなので実行のたびに同じ落ち方を繰り返すため。判定の出力も同じ。UTF-8 の BOM は
  読み取る前に外す（1 行目の番号が読めなくなるため）。
- 書き起こしが空の行（`2:`）は中断せず受け入れ、`tts_report.md` のヘッダーに空のチャンク番号を出す。
  中断すると取り直しで同じだけトークンがかかるため。空の書き起こしに判定が何も報告しなくても、
  「疑いなし」として正誤表から消えない。

#### 判定

- 判定の出力で `word`・`expected`・`heard` が null や欠落でも、空文字として受け入れる（必須は `chunk`
  だけ）。プロンプトは語の抜けや余分な語も報告させており、そのときは片側が無いため。
- 判定には、疑いごとに音声合成の読み間違い（`misreading`）か書き起こしの揺れ（`transcription`）かを
  選ばせ、理由を 1 文書かせる。書き起こしも別のモデルの聞き取りで誤りが混じるため。書き起こしの揺れと
  判断した疑いも正誤表から消さず、印と件数を付けて残す。どちらかを確かめるのは wav を聞く人で、
  判定のモデルの思い込みで本物の読み間違いが消えるのを避けるため。`cause` が無いか想定外の値の
  ときも、同じ理由で読み間違いとして扱う。
- 判定の出力からは、要素がすべてオブジェクトの JSON 配列（空配列を含む）として読めて、ほかの候補に
  含まれないものを探し、ちょうど 1 つのときだけ使う。前置きや後書きの `[注意]` のような括弧や文中の
  `[]` を答えとして選び、本物の指摘が黙って「疑いなし」になるのを防ぐため。判定のやり直しは安いので、
  決められないときは止める。判定の出力は保存するが読み直さず、再実行では判定をやり直す。
- 空配列を「疑いなし」と認めるのは、出力が `[]` だけ（コードフェンスで囲んだものを含む）のときに限る。
  本物の配列が JSON として壊れていると、要素の中の `[]` が唯一の候補として残り、黙って「疑いなし」に
  なるため。

### Publisher / Internal::Site（公開先の運用ルール）

公開されているサイトそのものを `Internal::Site`（`lib/internal/site.rb`）が表す。
`Publisher` は「エピソード資材を置く」「台帳を読み書きする」「サイトを反映する」
という語彙でしかサイトを触らず、**ストレージの種類・キー構成・デプロイ手段・
ベンダー名を一切知らない**。

- `Publisher` … 何を公開するか（台本・台帳・ページの内容）
- `Internal::Site` … サイトの状態と操作（キー構成・公開 URL・保持件数・反映）
- `Internal::R2Storage` … オブジェクトストレージの操作

`Publisher` が `Config` から直接読むのは `assets`（画像）だけで、公開先の設定は
`Internal::Site.from_config` が `cloudflare` セクションからまとめて読む。
`retention_episodes` は「保持する話数」という公開ポリシーなので、ストレージの
設定ではなく `Site` が持つ。

`Internal` 名前空間の中では `Config` が `Internal::Config` に解決されるため、
設定ローダーを参照するときは `::Config` と書く。

配信は 2 系統に分かれる。`index.html` / `feed.xml` / `manifest.json` / `sw.js` は Workers
static assets、それ以外（mp3 とその兄弟ファイル・画像・`archives.csv`）は R2。
両方を同一オリジンで配信するため CORS 設定は不要。

R2 のキー構成（台本の受け渡しと状態のキーは「RemoteState / Handoff」節）:

- `episodes/`: mp3 と兄弟ファイル。retention 超過分は退避する
- `assets/`: 画像などの恒久素材。退避しない（消えるとサイトの画像が壊れる）
- `archived/`: 退避済みエピソード
- `archives.csv`: 台帳（公開経路の外）

- **画像は R2 の `assets/` に置き、リポジトリにも配信成果物にも実体を持たない。**
  立ち絵などの版権素材を Git 管理下に置かずに済ませるため。`cover_image` /
  `icon_image` は `scripts/upload_assets.rb` で手動で置き、publish は URL を参照するだけ。
- 画像の `Cache-Control` は `Site::ASSET_CACHE_CONTROL`。ほとんど変わらないので長めに
  寝かせる。差し替えはキャッシュが切れるのを待つか、ファイル名を変えて参照を切り替える。
- オブジェクト名は渡された mp3 ファイル名をそのまま使うこと。日付から
  組み立て直すと slot が落ち、同日複数回のエピソードが同名衝突して上書きし合う。
- **mp3 とその兄弟ファイルは同じ `episodes/` プレフィックス配下に揃える。**
  再生ページの JS は mp3 URL の拡張子だけを差し替えて `.used.html` /
  `.transcript.txt` を引くため、階層が違うと兄弟ファイルの URL が壊れる。
  `.transcript.txt` の内容は読み仮名化前の人間可読な台本原稿だが、公開ページ上では
  「文字起こし」として提示する。
- **retention 超過分の退避先は `episodes/` の外（`archived/`）にする。**
  `episodes/` 配下に置くと Worker が R2 から配信し続け、公開を終えたはずの回が
  読めるままになる。
- `archives.csv` も `episodes/` の外に置く。ただし**プレフィックスの外に置くだけでは
  非公開にならない**: static assets に無いパスは Worker にフォールバックするため、
  Worker 側で配信可能なプレフィックス（`SERVABLE_PREFIXES`）を許可制にして塞ぐ。
- `ObjectNotFound`（`Internal::ObjectStorage`）は R2 実装固有の例外をラップした共通例外。
  ストレージの実装を差し替えても、捕捉する例外クラスを変えずに済む。
- `R2Storage#exist?` は「オブジェクトが存在しない」と「確認自体に失敗した」を区別し、
  NotFound だけを false にする。判定不能な失敗を「存在しない」扱いにすると、archives.csv を
  「初回で台帳が無い」と誤認し、既存台帳を新規 1 行で上書きして全履歴を消失させかねない。
- **R2 にサーバーサイドの move / rename は無い。** 退避は CopyObject +
  DeleteObject の 2 段構えで、copy の成功を確認してから delete する。途中で
  失敗したときは「元が残る」方に倒す（二重に存在するだけなら次回リトライで
  解消でき、公開物も壊れない）。退避先キーが決定的なのでリトライは冪等。
- `archived/` への退避は publish 時に自動で行われるが、実削除はされない。実削除は
  `Publisher#clean_archive` を明示的に呼んだときだけ行う。
- **素の `wrangler deploy` を使わない。** `wrangler.jsonc` に `assets.directory` を
  書くと、そのディレクトリの中身で公開サイト全体が置き換わる。`directory` を書かない
  ことで素の deploy はエラーで止まり、`--assets <ステージング>` を渡す publish 経路
  だけが通るようにしている。Worker の変更を反映したいときも `republish-ui` を使う。
- **static assets のデプロイはバージョン単位で、ステージングに無いファイルは
  公開サイトから消える。** そのため `Publisher#run` / `republish_ui` のどちらも、
  生成物（index.html / feed.xml / manifest.json / sw.js）を毎回すべてステージングに
  書き出し、`Site#deploy` が `_headers` を足してから 1 回だけ deploy する。sw.js も `web_push` の有無に
  関係なく毎回書き出す（消えると登録済みの Service Worker が更新されず購読が壊れる）。
- `_headers` で `feed.xml` の `Content-Type` を `application/atom+xml; charset=utf-8`
  へ明示的に上書きする。拡張子ベースの既定推定だと `.xml` は `application/xml` 系に
  なるため。
- **`_headers` は `run_worker_first` のパスに適用されない。** mp3 と兄弟ファイルの
  `Content-Type` は、Ruby 側が R2 の put 時に設定した値を Worker が `writeHttpMetadata` で
  反映することで初めて正しくなる。どちらかが欠けると兄弟ファイルが
  `application/octet-stream` で返る。
- static assets は **`/index.html` を `/` へリダイレクトする**ため、公開 URL としては
  正規形の `/` を使う（`Site#page_url`）。
- Worker（`src/index.js`, `src/web_push.js`）のテストは Vitest（`npm test`）。CI では
  走らせていない。配布されるファイルなのでコメントは書かず、以下に意図を記録する。
- Worker が R2 から返すのは `SERVABLE_PREFIXES`（`episodes/`・`assets/`）の下だけで、ほかに
  `/subscribe`・`/notify` を処理する。static assets に無いパスはすべて Worker に届くため、
  それ以外のパスは Worker 側で 404 にする（前掲の `archives.csv` の項）。
- `get` に `onlyIf: request.headers` と `range: request.headers` をそのまま渡し、
  条件付きリクエストと Range を R2 側に解釈させる。音声のシークが Range に依存する。
- `writeHttpMetadata` は R2 オブジェクトのメタデータでヘッダーを上書きするため、
  `cache-control` の既定値を入れるのは必ずその後。
- `body` を持たない応答は条件付きリクエストが不成立だったケース。`If-Match` /
  `If-Unmodified-Since` が付いていたときだけ 412 を返し、それ以外は 304。
- **206 を返すのはリクエストに `Range` があったときだけ**にする。R2 は `Range` が無くても
  `object.range` にオブジェクト全体を表す値を入れて返すため、`object.range` の有無だけで
  分岐すると**全リクエストが 206 になる**。Slack などのクローラーは 206 を画像として
  扱わず、OGP 展開が黙って壊れる。
- 206 の `content-range` は `object.range` の 3 形（`{offset, length}`・`{offset}` のみ・
  `{suffix}`）すべてから組み立てる。`Range: bytes=-N` では R2 が `{suffix: N}` を返すので、
  `offset`/`length` だけを見ると本文とヘッダーが食い違う。

#### publish の順序と中断

- `Publisher#run` 中に R2 操作または `wrangler deploy` が 1 つでも失敗したら
  即 abort する。公開物が中途半端に不整合な状態のまま残らないようにするため。
- mp3 などの実体ファイルを R2 へ書き終えた後、`archives.csv` より先に `deploy_site` を
  実行し、それが成功してから `archives.csv` を書く（`write_ledger`）。逆順にすると、
  deploy だけが失敗したときに次回の実行で `newly_published` が false と判定され、
  退避も通知も二度と行われなくなる。
- retention 超過分の退避（`archive_episode_files`）は、台帳・サイトの反映が終わった**後**に
  行う。逆順にすると、反映が失敗したときに「ファイルは退避済みなのに公開中のページは
  移動前の場所を参照したまま」というリンク切れが残る。この順序なら退避が失敗して
  `warn` に留まっても、読者から見える台帳・ページは既に正しい。
- `.used.html` は `dist/` に実体を持たないストレージ専用の派生物なので、
  `EPISODE_FILE_EXTENSIONS` には含めず、退避時に別途足す。
- `Publisher#run` は R2 へ書き込む前に `build_archives` を済ませ、publish しようと
  している回が retention 件数の外（`expired_rows`）に落ちるなら abort する。そのまま
  進めると、アップロード直後の mp3 が同じ実行のうちに退避され、ページにも feed にも
  載らないのに新着通知だけが飛び、何度でも再 publish できてしまう。

#### feed と台帳

- Atom の `<id>` は RFC 4151 の tag URI（`tag:<host>,<date>:<specific>`）を使う。
  `<id>` は RSS リーダー側の新着重複判定キーなので、**配信 URL を入れてはいけない**。
  URL を入れるとドメインやパス構成を変えた時点で全エントリが新着として再通知される。
  - entry: `tag:<host>,<エピソードの日付>:<mp3 のベース名>`。ベース名に slot が
    含まれるので、同日複数回でも衝突しない。
  - feed 自身: `tag:<host>,<Publisher::FEED_ID_DATE>:feed`。**一度決めたら変えない**
    （変えると購読者が別フィードとして扱う）。
  - `rel="self"` の href は実際の配信 URL のままにする。
- tag URI の authority には発行日時点で管理していたドメインを使う（RFC 4151 の要求）。
  `Site#tag_authority` は `public_base` のホスト名から導出するので、`public_base` を
  変えると過去のエントリの id も変わる。
- `archives.csv` の `updated_at` 列は「publish を実行した時刻」ではなく
  「**コンテンツが変わった時刻**」を表す。`build_archives` は既存行と
  title / used_news を比較し、同一なら既存の `updated_at` を引き継ぐ。
  `updated_at` は feed.xml の `<updated>` の源であり、ここが「実行時刻」だと
  内容が同じ再 publish や `republish-ui` でも購読者全員に誤った新着通知が飛ぶ。
- 既存の `updated_at` が空文字の行からは引き継がず現在時刻を入れる。空のまま引き継ぐと
  `<updated>` が空になり Atom として壊れる。
- `build_archives` の並び替えキーは `[[date_tag, 日内順], updated_at]`
  （`Slot.lenient_sort_key_from_filename`）。日付だけで並べて同日内を `updated_at`
  に任せると、同じ日の早い slot を後から publish したときにその回が先頭に来てしまう。

#### Web Push 通知（購読者管理・送信は Worker 側に同居）

- 新規 episode の publish を Web Push で知らせる機能。`config.yaml` の任意セクション
  `web_push`（`vapid_public_key` のみ）が無ければ完全に無効化される。独立サービスへの
  切り出しはせず、既存の配信基盤（Cloudflare Workers + R2 + D1）に同居させている。
- 購読者ストアは Cloudflare D1。「全購読者への一斉配信リスト」は `SELECT` 1 回で
  全件取れる D1 が素直で、KV は書き込み制限と全件読み出しの手間が合わない。
- VAPID 署名・ペイロード暗号化は `web-push` npm パッケージを使うが、`sendNotification()` は
  Node の `https` に直接依存するため使わない。`generateRequestDetails()` でリクエストを
  組み立てるだけに留め、送信は Workers の `fetch()` で行う。署名と暗号化は Node 標準の
  `crypto`/`Buffer` に依存するため、`compatibility_flags: ["nodejs_compat"]` が必須。
- 購読の宛先が 404/410 を返したら、その `endpoint` を D1 から削除する。
- `POST /subscribe` の `endpoint` は既知の Push サービス（FCM/Mozilla/Apple/
  Microsoft WNS）だけを許可する。検証しないと任意のホストを登録でき、`/notify` が
  その都度そこへ `fetch` してしまう（SSRF・D1 の汚染）。
  - FCM/Mozilla/Apple はオリジンの完全一致で許可する。WNS はリージョンごとにホスト名が
    変わるため、`https`・既定ポートで `.notify.windows.com` に終わるホスト名を許可する。
    先頭の `.` を含めて照合するのは `evilnotify.windows.com` のような別ドメインを通さないため。
  - 送信は購読者ごとに try/catch する。1 件の不正な購読・到達不能ホストで `Promise.all`
    全体が reject すると、他の全購読者への配信と期限切れ購読の削除が巻き添えで止まる。
- `Internal::EpisodeNotifier#notify` は、通知の失敗を `abort` せず `warn` に留める
  （`deploy_site` が成功した後に呼ぶので、公開物の整合性に影響しないため）。Worker からの
  非 2xx 応答も例外にならないため、ステータスを明示的に見て `warn` する。見ないと
  Worker 側の認証エラーが "done" 表示に隠れて気づかれない。
- 通知の要否は `updated_at` の変化ではなく、`build_archives` が返す
  `newly_published`（`content_changed?` の結果）で判定する。feed.xml の `<updated>` を
  動かす条件と通知の条件を `content_changed?` 一箇所に集約し、片方だけ変えて
  タイミングがずれるのを防ぐ。`republish-ui` は `build_archives` を呼ばないので通知しない。
- `content_changed?` は `used_news_given`（`Publisher#run` に `used_txt_path` が
  渡されたか）も見る。`dist/` の整理で used.txt が消えただけの再 publish を「内容変更あり」と
  誤検知して再通知しないよう、渡されていないときは title の変化だけで判定する。
- `/notify` の認証は共有シークレットを Worker secret に置き、HMAC-SHA256 で検証する。
  config.yaml は「機密を持たないから git 追跡してよい」前提で運用しているため、
  シークレットは書かない。VAPID 公開鍵は秘密ではないので config.yaml に置いてよい。
- 送信は全購読者へループで `fetch` するだけなので、購読者が増えると Workers の
  サブリクエスト上限に当たる。その場合はバッチ分割やキュー処理が要る（未実装）。
- `src/index.js` は `web_push.js` を無条件に import するため、deploy する限り
  `node_modules/web-push` が必須になる。無いまま deploy すると終盤で初めて落ちるので、
  `miyamai_news.rb` は deploy に到達する起動（`republish-ui`、または publish まで進む工程）
  に限り、`Internal::NodeDeps.validate_wrangler_build!` で `wrangler deploy --dry-run` を
  走らせて fail fast する。依存の有無だけでなく `wrangler.jsonc` の不備も検出するため、
  実際に `wrangler` を動かす。`Site#deploy` と同じ bare `wrangler` を使う（`npx wrangler` に
  すると、実際の deploy とは別のバイナリを検証してしまう）。

### 旧 GCS feed の凍結（移行告知）

旧公開先（GCS）の feed.xml は、移転告知 1 件だけの静的な Atom に差し替えて凍結済み。
生成コードは持たず、以後更新しない。再編集する場合も、feed の `<id>` は旧 URL のまま
変えない（変えると既存購読者に告知が届かない）。

### LastFetchStore / 収集 window（last_fetch.json）

- `last_fetch.json`（`work/state/`）は、収集 window を確定した直近の回 `commits`
  （`{ episode: <episode_key>, at: その回の収集時刻 }`、新しい回から `KEEP_COMMITS` 件）
  だけを持つ。ある回の収集 window の起点は、その回より前の確定のうち最新のものの `at`
  （`since_for`）で、起点を別に持たない（持つと確定履歴とずれうる）。確定が無ければ
  `collect.lookback_hours` 前から。並びは書き込み順ではなく episode_key の時系列で決める。
- 確定は台本を R2 に置く直前（`Pipeline#commit_episode!`）に行い、音声合成・publish を
  待たない。draft と synthesize/publish は別の実行（VOICEPEAK の無いマシンでも draft
  できる）に分けたため。代償として、台本を置いた後でその回を公開せずに捨てても、
  その回の記事は確定済み・紹介済み履歴に記録済みのまま残る。確定を取り消す操作は持たない。
- 確定にラベル（episode_key）を付けるのは、確定済みの回を作り直すため。その回自身の `at` から
  収集するとその回の記事が `seen_at ≤ since` で落ちるので、起点は「その回より前の確定」から
  取る。履歴からはその回を除いて selector に渡し、確定は二重に積まず置き換える（`commit!`）。
  最新の確定より古い回は、後の回と収集範囲が重なるので作れない（`OlderEpisodeError`）。
- 最新の確定の回を作り直すときも、前の確定の `at` 以降を fetch する（収集範囲に上限は
  付けない）。スキップの時間を過ぎてから作り直すと、初回の後にフィードから落ちた記事は
  候補に戻らないが、候補一覧を別に保存しないのはこの差を許容しているため。
- 確定する収集時刻（`at`）は、収集時に `work/news_collected_at_<episode_key>.txt` へ書き、
  `Pipeline#commit_episode!` がそれを読む。収集したプロセスが途中で落ちて別プロセスが
  中間ファイルを再利用しても、収集した時点の時刻で確定できるようにするため。
  回ごとの中間ファイルなので R2 には同期せず、`clean` で消える。
- `read_data` は、last_fetch.json が valid JSON だが Hash でない壊れ方をしていた場合、
  デフォルト値で上書きせず abort する。上書きすると手動修復の余地を失うため。
- `publish` コマンドは収集 window に一切触らない。`draft --until digest`/`draft --until script` は
  状態を R2 へ書き戻さないので、収集 window を進めない。

### ScriptGenerator / AI パイプライン

- 各ステップ（収集・選定・facts 抽出・script+used 生成・整形）は work_dir 内の
  中間ファイルの有無で再利用を判断する。途中でクラッシュしても、存在する中間
  ファイルはそのまま使い、続きから再実行できる。
- `OPENING_GREETING`（"宮舞モカです。"）は台本の挨拶文であると同時に、
  `strip_preamble` が AI 出力の前置き除去に使う目印（アンカー）でもある。
- `feed_cache/`・`last_fetch.json`・`used_news_history/` は実行をまたいで保持する内部状態で、
  `clean` は対象にしない（`work_globs` が列挙する回ごとの中間ファイルのみが削除対象。
  ホワイトリスト方式なので状態ファイルは自動的に残る）。消すと過去に見た記事を新着として
  拾い直し、重複紹介が起きるため。正は R2 の `state/` で、`work/` のこれらは作業コピー
  （「RemoteState / Handoff」節）。
- 収集 window の起点として記録する時刻は、実行完了時刻ではなく収集開始時刻
  （`@now`）。開始〜完了の間に seen_at が刻まれた記事を次回取りこぼさないため。
- ニュースの重複除去はタイトル基準（大文字小文字・空白を無視）。同一タイトルが
  複数ソースにまたがる場合、`priority: high` のソース由来の entry を代表として
  残す（一次情報源の priority ラベル・URL が選定 AI に渡るようにするため）。
  同順位なら config の記載順で先勝ち。
- writer は抽出済みの facts シートだけに基づいて書かせ、Web への再アクセスをプロンプトで
  禁止する（手戻りと情報の食い違いを防ぐため）。
- AI CLI のツール制限は呼び出し元ごとに絞らない。claude 分岐は `--allowedTools` で固定の
  ツールを許可し、agy 分岐は `--dangerously-skip-permissions` で全ツールを許可する
  （用途ごとに出し分ける利点が薄いため）。
- `category_details` は「AI への執筆方針の指示」と「used_news のカテゴリ見出し
  （`## ラベル名`）として使う正式なラベル一覧」を兼ねる。`UsedNewsFormatter.strip_preamble`
  はこの「##」見出しが本文の先頭に来る構造に依存しているため、ラベル文言・見出し規則を
  変える際は合わせて確認すること。
- AI CLI の出力には、プロンプトで禁止していても前置き文（「整形しました」等）がまれに
  混入する。`strip_preamble` 系はいずれもこれを機械的なアンカー探索（挨拶文・見出し）で
  除去する。アンカーが見つからなければ入力をそのまま返す（削ぎ落として誤魔化すより、
  人間が壊れた入力に気づける形にするため）。
- RSS ソースの `priority` は選定 AI への判断材料（ヒント）に過ぎず、掲載/除外を
  保証するものではない。

#### 収集の失敗の扱い

- 1 つのフィードの障害で回全体を作れなくなるのを避けるため、取得に失敗したソースは
  その回だけ飛ばし、残りで収集を続ける。飛ばしたソースは収集直後の件数表示に
  `skipped (fetch failed)` として出し、実行ログにも `feed_skipped` として残す。
  同じ回を `news_*.txt` の再利用で作り直す場合、飛ばしたソースは取り直さない。
  飛ばしたソースの記事は次に取得できたときに初めて seen_at が付き、次の回の収集範囲に
  入るため、その回で取りこぼしても失われない（次の取得までにフィードから押し出された
  記事は拾えない）。
- 取得に失敗したソースが `collect.fetch_failure_abort_threshold` に達したら、実行全体を
  中断する。失敗が重なるときは実行環境側の障害（回線断など）を疑い、その回を作らずに止める。
- 閾値に達した時点で、まだ取りに行っていないソースは取得しない（キューを空にする）。
  全断時は 1 試行ごとにタイムアウト待ちが発生するため。実行中の試行は最後まで続くので、
  中断メッセージに挙がる失敗ソースの数は閾値を超えることがある。
- ソース数が閾値より少ない構成でも、全ソースの取得に失敗したときは中断する（候補ゼロの
  まま AI を呼んでもトークンを浪費するだけのため）。新着が 0 件だった場合は中断しない。
- `FeedCache` は収集のたびに `build_feed_cache` で作る。リトライの締め切りを収集開始時点から
  数えるため。
- 収集ワーカーは `abort_on_exception` を立てて動かす。想定外の例外（不具合）で 1 本が
  落ちたとき、他のワーカーのリトライが終わるまで報告が遅れないようにするため。
- `CollectStats#per_source` の単純合計と `total_after_dedup` は、ソース間のタイトル重複を
  除くため一致しないことがある。両方を別フィールドで持つのはこのため。
- 中間ファイルを再利用した場合、`collect_stats` は `nil` のまま件数表示をスキップする
  （実際には収集していないので、0 件という偽の値を出さない）。

#### AI CLI（Internal::AiCli）と agy

- AI CLI の実行ロジックは `Internal::AiCli` に集約し、`ScriptGenerator`（selector/extractor/
  writer/format）と `UsedNewsFormatter`（修復）が直接呼ぶ。失敗時に abort するかは
  `fatal:`（既定 `true`）で表す。`effort_override:` は既定の `:default` なら
  `Config.ai_agent.effort` を使い、`nil` なら `--effort` を渡さず CLI の既定に任せる。
- agy の `-p` は stdin からプロンプトを読めないため、プロンプトは argv で渡す。ARG_MAX を
  超えるリスク（Issue #90）は承知の上の制約。
- agy にはワークスペースを明示するため、`--add-dir` に `Dir.pwd` を渡す。project scope の
  プラグイン（後述）もこのワークスペースから解決される。
- agy 上のモデルは、プロンプト末尾の出力指示（書き込み先・形式）を無視しやすい。そのため
  書き込み先と「Write ツールで」をタスク説明の直後に置く。selector は入力ニュースを本文で
  埋め込まず、パスを渡して Read させる（プロンプトを削り、書き込み指示の埋没を避けるため）。
- extractor と writer はニュース本文をプロンプトに埋め込むので、本文中の `/コマンド` が agy の
  スラッシュコマンドや skill として展開されうる。防ぐため、AiCli は agy に
  `--disable-slash-commands` を渡す。
- agy 組み込みの URL 取得ツール（`read_url_content`）は、Shift_JIS のページなどで agy ごと
  落ちることがある。AiCli はツールを絞っていないので、extractor のプロンプトで使用を禁止し、
  MCP 経由の `fetch_readable` を使わせる。
- extractor.prompt.erb は `bin` を見分けず、「`fetch_readable` が使えればそれ、無ければ
  `WebFetch`」とツールの有無で分岐させる。モデルが自分の実行バイナリ名を認識している保証が
  なく、バイナリ名で分岐させるとどちらにも該当せずクラッシュが再発しかねないため。
- `fetch_readable` は `fetch-mcp`（npm `mcp-fetch-server`）を project scope の agy プラグイン
  （`.agents/plugins/fetch-tools/`）として入れて使う。agy の MCP 登録はグローバル設定に
  書かれるため、リポジトリにコミットできるプラグインにしている。
  - パッケージのバージョンを固定する。未固定だと定期実行のたびに最新版を解決し、上流の
    破壊的変更やレジストリ障害がそのまま本番の障害になるため。
  - `DEFAULT_LIMIT` を上げているのは、既定では extractor がメイン候補に求める 3 観点を書くには
    本文が短く切れすぎるため。無制限にはしない（全記事の本文がプロンプトに乗るとトークンが
    膨らむため）。
  - extractor を agy で動かす環境には `npx` が要る。
- プラグインが読み込まれないワークスペースで agy を動かすと、`fetch_readable` のフォールバック
  先の `WebFetch` が agy に無いため、`read_url_content` に戻ってクラッシュが再発しうる。
  実行ディレクトリがリポジトリルートである限り起きないが、変えるときはこの項目を確認すること。
- **`fetch-mcp` は charset を見ないため、Shift_JIS ページの日本語が復元できない形で化ける。**
  extractor のプロンプトで、文字化けした記事はファクトシートにも used_news にも採用しない
  よう指示している（タイトルや要約からの推測で埋め合わせるのを防ぐため）。**結果として
  Shift_JIS で配信しているサイトの記事は番組から恒常的に落ちる**（agy のクラッシュを止める
  ために受け入れたトレードオフで、別のバグではない）。
- `Internal::AiCli.run` は `ai_agent.print_timeout` を `--print-timeout` として渡す。extractor は
  agy の既定の時間では足りないことがあるため。打ち切りは終了コードに表れないことがあるので、
  終了コードに加えて stderr の目印でも検知する。打ち切りを検知したら `cleanup_paths_on_timeout` の
  ファイルを消してから abort する（Write の直後に打ち切られた途中出力を、次回の再利用判定で
  拾わないため）。修復（`used_fix`）も同じ時間まで待つ。

### Pipeline（フェーズ計測）

- `Internal::PhaseTimer#measure` の `"digest"` ラベルは、draft のどの経路でも
  collect→select→facts を計る。後に何が続くかは区別しないので、複数の実行ログを横断して
  集計するときは文脈が混ざる前提で扱うこと。

### EpisodeLogger（実行ログ）

`Internal::EpisodeLogger` は、AI CLI・VOICEPEAK・HTTP フェッチの stdout/stderr・所要時間・
リトライ回数等を `work/<date_tag>_<slot>.log` にプレーンテキストで追記する記録係で、
以下の不変条件を持つ。

- **Config と同じモジュールレベルのグローバル状態**。`Pipeline#setup_episode!` で
  一度だけ `configure(path)` する。episode の概念を持たない呼び出し元（`AiCli`・
  `UsedNewsFormatter`・`HttpFetcher` など）が多く、個別に `log_path` を注入すると
  シグネチャ変更が広範囲に波及するため。
- `configure` されるまで（`clean`/`republish-ui` など episode を作らない経路）は `record` が
  no-op になる。これらの経路は AI CLI や VOICEPEAK を呼ばない。
- **常に追記（truncate しない）**。`draft`→`synthesize`→`publish` を別プロセスで
  順に実行する運用があり、切り詰めると前段の実行ログが消えるため。
- 収集は複数スレッドから同時に `record` を呼ぶため、内部の Mutex で 1 エントリの書き込みを
  synchronize する。
- 所要時間は monotonic clock で計る（NTP 補正の影響を受けないため）。呼び出し単位の計測は
  ブロックで包まない（主処理がブロックの中に埋もれて読みにくくなるため）。
- 実行した argv（`cmd`）はログに出さない。agy 分岐ではプロンプト全文が argv に入るため。

### used_news の表示フォーマット（Markdown サブセット）

再生ページ（index.html）と feed.xml の「この回で紹介したニュース」欄（used_news）は、
以下の限定 Markdown サブセットで書き、構造化 HTML に変換して表示する。**この文法の
唯一の実装は Ruby 側（`lib/internal/used_news_markdown.rb` の `UsedNewsMarkdown`）**。

- 行単位で解釈する（ブロックレベルのみ。インライン強調・コードは扱わない）。
  - カテゴリ見出し: `^##\s+(.+?)\s*$` → `<h3 class="news-cat">…</h3>`
  - 記事タイトル: `^###\s+\[(.+)\]\((\S+)\)\s*$`（`[...]` は貪欲）→
    `<div class="news-item"><p class="news-title"><strong>…</strong></p>`
  - メタ行: `^\s*\((.+)\)\s*$` → 直近項目の `<p class="news-meta">(…)</p>`
  - 要約行: 上記いずれにもマッチしない空でない行 → 直近項目の `<p class="news-sum">`
  - 空行: 項目区切り（無視）
- カテゴリ見出しは `<h3>` にし、記事タイトルは `<p><strong>` にとどめる。CSS が当たらない
  環境（RSS リーダー等）でもブラウザ既定のスタイルだけで見出し・強調・段落が最低限つく
  （feed.xml の `<content type="html">` は CSS を運べないため）。
- **貪欲マッチの理由**: タイトルに `]` や `)` を含む記事がある。URL に空白は入らない前提
  なので、最後の `](URL)` を境界にできる。
- **エスケープ**: タイトル・要約・メタは HTML エスケープしてから埋め込む。URL は
  `http/https` で始まる場合のみ `<a>` 化する（XSS 防止）。
- **失敗（ok=false）条件**: (a) `##` 見出しが 1 つも無い、(b) `### [...](...)` タイトル行が
  1 つも無い、(c) 見出しの前に孤立したタイトルがある等の破綻、(d) 例外発生。
- パーサを Ruby だけに置くため、Publisher が publish 時に used_news を HTML 化し、
  `.used.html` としてストレージへ置く。`ok=false` のときは `.used.html` を作らず、再生ページの
  JS は `.used.txt` の生表示にフォールバックする。feed.xml は `ok=false` のとき URL リンク化 +
  `<br>` の簡易 HTML で埋める（feed の content は空にしないため）。

#### フォーマット保証は UsedNewsFormatter が担う

- used_news のフォーマットを検証・保証するのは **`UsedNewsFormatter`**
  （`lib/internal/used_news_formatter.rb`）で、`ScriptGenerator` ではない。ScriptGenerator は
  AI が書いた生のテキストをそのまま work/ に残す。
- `UsedNewsFormatter.ensure_valid!` は、前置き除去 → `UsedNewsMarkdown.render` で検証 →
  崩れていれば軽量モデルで修復、の順に整えて返す。修復後も直らなければ `abort` する。
  呼ぶのは 2 か所で、どちらもストレージへ書き込む前に止める。
  - handoff を置く前（`Pipeline#prepare_handoff`）。修復結果は work/ にも書き戻す。
  - publish の前（`Publisher#run`）。handoff の時点で検証済みなので、通常は修復が要らない。
- used_news が無い回（空文字列）は早期 return し、AI 呼び出し・abort を行わない。
- 修復 AI の出力は stdout ではなく一時ファイル（Write→Read）で受け渡す（stdout は前置き・
  コードフェンス等のノイズが混入しやすいため）。修復 AI が記事を捏造/欠落させないよう、
  整形後の URL 集合が入力と一致することを Ruby 側で強制する（`preserves_urls?`）。
- 修復プロンプトの描画に渡す `UsedNewsFormatter::PROMPT_CONTEXT` は空のオブジェクトで、
  `fix_format.prompt.erb` はローカル変数だけを参照する前提。テンプレートでヘルパーを
  使い始めたら、context も用意すること。
- `ai_agent.used_fix_max_retries` に `0` を指定すると、AI を一切呼ばずに修復失敗として扱う
  （修復機能そのものを無効化できる）。

### UsedNewsHistory（紹介済みニュース履歴）

- なぜ必要か: 別ソースが同じ話題を配信すると FeedCache の `seen_at` が振り直されて「新着」
  扱いになり、直前の回で紹介したニュースが次の回でも選ばれてしまう（回またぎの二重紹介）。
  `dedup_by_title` は同一実行内しか効かない。そこで直近 N 回
  （`collect.used_news_history_episodes`）の紹介済みニュースを
  `work/state/used_news_history/<episode_key>.txt` に貯め、selector プロンプトの
  `<recently_used>` として渡し、AI に link 一致・話題一致で避けさせる（Ruby 側の機械
  reject ではなくプロンプトベース）。
- 要約を持たせる理由: 別ソース・別 URL でも「同じ話題」を AI が判断できるよう、used_news
  に 1〜2 文の要約をタイトル直下に載せる。副次的に再生ページ・feed にも要約が出る。
- 要約の文末は writer のプロンプトで「〜しました。」にそろえる。指定が無いと語調が項目ごとに
  ばらつくため。extractor の暫定版は再生ページに出ないので、そろえる指定をしていない。
- used_news を書く工程は 2 つある。extractor が facts と一緒に**暫定版**
  （`news_used_provisional_<episode_key>.txt`。facts 化した全ニュース）を書き、writer が
  **確定版**（`news_used_<episode_key>.txt`。台本で実際に紹介したもの）を別パスに書く。
  暫定版は副産物なので書き損ねても止めないが、確定版の欠落は abort する。
  **別パスにするのは、writer が書き損ねたときに暫定版が確定版として素通りしないため。**
- 履歴に記録するのは handoff まで進む実行の確定時だけで、`draft --until digest`/`script` は
  記録しない。`record_used_news_history!` は確定版が無ければ暫定版を使うが、handoff 経路では
  確定版の欠落で先に abort するため、暫定版が履歴に入ることは通常ない。
- 履歴は機械パースせず、used_news のテキストをそのまま selector プロンプトに埋め込む。
  ただし URL はノイズになるので履歴に写すときに落とす（`strip_links`）。公開用
  `dist/*.used.txt` には link を残す。
- 中間ファイル `news_used_*.txt` は `clean` で消えるため、履歴は必ず `work/state/` 側へコピーする。
- 1 回の単位は episode_key（`<date_tag>_<slot>`）。同一 key への再記録は上書き（冪等）。
  古い回の削除は `(date_tag, Slot.sort_key(slot))` で判定する（mtime 非依存）。`midnight` は
  前日回に寄るため、同一 date_tag 内では日内の最後になる。未知形式の key は最古扱いに寄せ、
  壊れた key が混じっても削除処理が壊れないようにする。
- 追記タイミングと不変条件: 収集 window の確定時（`Pipeline#commit_episode!`）にだけ
  追記する。selector は「前回まで」の履歴を読むので、自回の追記は selector より必ず後で
  なければ自回を過去回として弾いてしまう。確定済みの回を作り直すときは、selector に渡す
  履歴からその回を除く（`render_for_prompt(exclude:)`）。

### Config

- `Config.validate_publish_target!` は、工程の判定を通らずに公開先（R2）を触る CLI 操作
  （`clean` / `clean --archive`）のためにある。`republish-ui` は `assets` も参照するため
  `Config.validate_sections!("cloudflare", "assets")` を直接呼ぶ。`validate_sections!` は
  工程と無関係に、個別の CLI 操作が参照するセクションだけをその場で検証する共通の本体。
- `cloudflare` セクションは全工程共通の必須セクション（`REQUIRED_SECTIONS_BASE`）。
  draft・synthesize・publish のどの工程も R2 に触るため。
- 必須セクションは、そのコマンドがたどる工程の範囲（`Config.validate_for!(stage, from:)`）
  に含まれる工程の分だけを合算する。handoff を境に実行環境の前提が変わる（前半は AI CLI と
  ニュースソース、後半は VOICEPEAK・ffmpeg・wrangler）ので、音声側の環境に不要な設定を
  強いないため。
- publish の必須セクションに `ai_agent` を含めるのは、`Publisher#run` が used_news を
  `UsedNewsFormatter.ensure_valid!` に通し、壊れていれば AI CLI で修復するため。
  `assets` は配信物（カバー画像・アイコン）の生成に使う。
- R2 の S3 互換 API 認証情報（`R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`）と
  wrangler の認証（`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`）は
  config.yaml に置かず環境変数で渡す。config.yaml は「機密を持たないから git で
  追跡してよい」という前提で運用しているため。`Internal::R2Storage` は環境変数の読み取りを
  最初のリクエストまで遅らせる（R2 に触らない経路でも環境変数が無いと落ちないように）。
- `cloudflare.episode_prefix` は `wrangler.jsonc` の `assets.run_worker_first` と揃える
  （片方だけ変えると mp3 が static assets 側にルーティングされ 404 になる）。
- `Config.path=` は代入した時点で新しいパスから読み直す。`miyamai_news.rb` は `--config`
  指定時の読み込みエラーもまとめて拾えるよう、代入と検証を同じ begin ブロック内に置く。
- `AppConfig` は到達する工程によってセクションの要否が変わるため、全セクションを任意属性
  （`attribute?`）にし、必須判定は `Config.validate_for!` 側で行う。
- `pipeline.until` は工程名（digest/script/handoff/synthesize/publish）をとり、その環境で
  進んでよい工程の上限を表す（例: VOICEPEAK の無いリモートは handoff、公開させたくない
  端末は synthesize）。

### miyamai_news.rb（CLIエントリポイント）

- CLI 引数の解析と config 検証のみを担い、工程の呼び分けは `Pipeline` に委譲する薄い層。
- 起動時の config 検証: `republish-ui`/`clean` は公開先を触るため個別に検証する（前掲
  「Config」節）。それ以外は、実行中に MissingKeyError で中途半端に失敗しないよう、
  起動直後にこの起動がたどる工程の範囲（`Pipeline.stage_range_for(ARGS)`）に必要な config を
  一括で検証する。上限（`pipeline.until`）ではなく実際の範囲で検証するのは、publish 環境の
  config でも `draft --until digest` なら voicepeak 等を外したまま動かせるようにするため。
- `--until` の値は OptionParser の候補配列ではなく、`draft` がたどる工程との完全一致で
  検証する。候補配列を渡すと前方一致で補完され、打ち損じが黙って別の工程として通るため。
  `pipeline.until` の値もロード時に完全一致で検証する（`Config.ensure_known_stage!`）。
- サブコマンドは handoff を境にした実行環境の違いに合わせて分ける。`draft`（AI 環境:
  収集〜台本〜R2 handoff）・`synthesize`（VOICEPEAK 環境: R2 handoff から音声化）・
  `publish`（dist/ から公開）と、続けて実行する `synthesize-and-publish`・
  `draft-synthesize-publish`。続けて実行するコマンドは、たどる工程をすべて名前に出す
  （将来テキストだけ先に公開する構成にしても、名前の意味が変わらないように）。
- `--config` のパスは cwd 基準で解決する。`__dir__` 基準だと、リポジトリ外から相対パスを
  指定したときに意図と異なる場所を読むため。
- Gemfile で rss/csv/rexml を明示しているのは、これらが bundled gem で、明示しないと
  `require` できないため。
- サブコマンドの省略（デフォルト実行）は認めない。引数なしで生成〜公開まで走ると、
  意図しない本番 publish が起きうるため。
- サブコマンドが受け付けないオプション（`publish --until` 等）は黙って無視せず abort する。
- `Pipeline.stage_range_for` は `Pipeline::STAGE_RANGES` に無いコマンドを `ArgumentError` に
  する。既定のコマンドに落とすと、`COMMANDS` にだけコマンドを足して `Pipeline` 側を直し
  忘れたとき、その起動が本番 publish まで走ってしまうため。

### Pipeline（工程オーケストレーション）

- `miyamai_news.rb` のサブコマンド・`--until` に応じた工程の呼び分けと、その間の副作用
  （work/dist の mkdir・`Internal::EpisodeLogger` の configure）を一元管理する。
  新しいドメインロジックは持たず、既存のコンポーネントの呼び出し順序を集約するだけに徹する。
- `clean`/`clean --archive`/`republish-ui` は Episode を作らないため、`#run` はこれらを
  Episode 構築（`#setup_episode!`）より前で早期 return して処理する。
- `synthesize`/`publish` で始まるコマンドは新規収集を一切行わないため、`ScriptGenerator` を
  生成しない。
- `synthesize` で始まるコマンドは、R2 にこの回の handoff が無ければ生成せずに abort する。
  音声側の環境は AI CLI やニュースソースの設定を持たない前提で、そこで収集・生成を始めると
  R2 の内部状態まで書き換えてしまうため。生成から続けたいときは `draft-synthesize-publish` を使う。
- `draft --until script` は VOICEPEAK 向けの整形をしない、人間が読む台本までで停止する。
  台本を確認・手直ししてから `draft` 等で再実行すれば、中間ファイルの再利用で続きから進める。
- `clean` は作業コピーの取得元 revision（`.state_base_revision`）を消す。未完了の実行の
  作業コピーを破棄する手段になる。
- BGM の作者名は `templates/index.html.erb` に固定で書いている。`assets.bgm_path` を変える
  ときはクレジット表記も直すこと。
- `--ci` は、進捗表示をスピナーではなく開始と結果の 1 行ずつにする。CI のログに制御文字や
  再描画が残らないようにするため。
- 現在の回以外に、台本一式が揃った handoff が R2 に残っていれば警告する
  （`Pipeline#warn_other_pending_handoffs`）。拾わないまま次の slot に進むと、その回は公開されず、
  記事は確定済み・紹介済みとして扱われたまま残る。`--date`/`--slot` でその回を指定すれば
  合成・publish できる（handoff があれば収集し直さないので、最新の確定より古い回でも作れる）。
  ただし retention 件数分より古い回は `Publisher#run` が abort する。
- VOICEPEAK の無いリモートは `draft` を `pipeline.until: handoff` の config で動かす。
  台本の生成に必要なのは digest の必須セクションだけなので、voicepeak/mixer/assets を
  持たなくても起動時検証を通る。
- `Pipeline.stage_range_for` は、コマンドの到達工程が `pipeline.until` を超えると
  `StageNotAllowed` にし、`#run` は Episode 構築より前に abort する。`StageNotAllowed` は
  `ArgumentError` の派生にして、`miyamai_news.rb` の起動時の rescue でも拾えるようにしている。
- `#clean_published_dist`（`Publisher#prunable_from_dist`）は、R2 の物理配置を見ず、台帳
  （`archives.csv`）と命名規則だけで dist/ の削除対象を決める。R2 の `episodes/` を見ると、
  `archived/` へ rotation 済みの回を「未公開」と誤判定して dist/ に残し続けるため。
  - 削除対象は「台帳にある（公開中）」か「台帳の現存最古行より古い」もの。「台帳に無く、
    かつ境界内（publish 前の作業中の回）」だけを残す。境界より古い未公開の回も消える
    （ローカルの `dist/` だけで、公開物には触らない）。
  - 境界の比較は `[date_tag, 日内順]` の `<=>` で行う（date だけでは同日複数 slot の境界を
    取り違える）。
  - 台帳側は `Slot.lenient_sort_key_from_filename` で slot の無い行も date_tag だけから境界に
    含める。無視すると境界が新しい方へ繰り上がり、保持期間内の未公開ファイルまで消える。
    dist 側は厳密に判定し、抽出できなければ台帳とのメンバーシップだけで扱う。
  - ファイル名からの `[date_tag, 日内順]` の抽出は `Slot.sort_key_from_filename` に一本化し、
    `UsedNewsHistory#episode_sort_key` もこれに委譲する（基準のドリフトを防ぐため）。

### RemoteState / Handoff（R2 を経由した台本の受け渡し）

台本生成（収集〜TTS 整形。リモートでも動く）と音声合成（VOICEPEAK のある手元）を
別の実行に分けられるよう、両者の受け渡しは同じ端末で続けて実行する場合も含めて必ず R2 を
経由する。`state/`・`handoff/`・`handoff_done/`・`state_revision` はいずれも Worker が
配信しないプレフィックスなので、公開サイトからは読めない。

- 「現在の回」（`--date`/`--slot` を省略したときの date/slot）は、端末のタイムゾーンによらず
  実行時刻を JST に直してから決める。UTC で動くリモートと JST の手元で slot・日付がずれると、
  リモートが置いた handoff を手元が見つけられなくなるため。slot の区切りも挨拶文も JST 前提
  なので、設定にはせず固定している。瞬間としては同じ時刻なので、収集時刻（`seen_at`・確定の
  `at`）の比較には影響しない。
- handoff まで進む実行（`Pipeline#prepare_handoff`）は、まず R2 に現在の回の
  `handoff/<episode_key>/` があるかを見る。あれば生成も状態の取り出しもせずに次へ進む。
- handoff が無い場合、公開済みかどうかは `handoff_done/` ではなく公開台帳（`archives.csv`）で
  判定する。台帳が公開状態の唯一の正のため。公開済みなら生成せずに中断する（同じ回を
  作り直して publish し直すと feed.xml が動きうる）。
- handoff が揃っているかは、別の目印ファイルを置かず、台本一式（`Handoff::FILES`）が R2 に
  全部あるかで判定する。
- 生成する実行の書き込み順は、収集 window の確定・紹介済み履歴への記録 → 内部状態の
  書き戻し（`RemoteState#push!`）→ 台本一式のアップロード（`Handoff#upload!`）。
  台本を内部状態の書き戻しより先に置くと、書き戻し前に落ちた場合に再実行が「handoff あり」の
  経路へ入り、確定・履歴記録・書き戻しが二度と行われない。書き戻し後・アップロード前に
  落ちた場合は、確定済みの内部状態から生成し直す（中間ファイルを持たない環境では、
  確定済みの記事が候補から外れた台本になる）。
- アップロードする used_news は `UsedNewsFormatter.ensure_valid!` で検証・修復した内容で、
  修復結果は `work/` にも書き戻してから紹介済み履歴に記録する。公開した一覧と重複回避の
  元データがずれないようにするため。
- 音声合成側が used_news・台本を dist/ へコピーするのは、音声合成・BGM 合成が成功した後。
  合成に失敗したとき dist/ に mp3 の無い used/transcript だけが残らないようにするため。
- `Handoff#mark_done!` は `tts_script.txt` から先に `handoff_done/` へ移す。途中で落ちても
  `handoff/` 側は「揃っていない」扱いになり、再実行で同じ台本を合成し直さない。同じ回の
  `publish` を再実行すれば残りも移る。再実行しなければ残りは `handoff/<episode_key>/` に
  残り続ける（揃っていないので誤って使われず、自動では掃除しない）。
- パイプラインの内部状態は `work/state/`（`StateDir`）にまとめ、R2 の `state/` と 1 対 1 に
  対応させる。R2 側が正で、`work/state/` は作業コピー。同期（`R2Storage#sync_down` /
  `#sync_up`）は削除も反映する（`sync_down` は取得前に `work/state/` を消し、`sync_up` は
  アップロード後にローカルに無いキーを消す）。回ごとの中間ファイルは同期しない。
- `RemoteState#push!` は、同期より先に `state_revision` を進め、作業コピーの取得元 revision も
  それに書き換える。同期の途中で落ちても、他の作業コピーは衝突として止まり、この作業コピー
  からの再実行は引き継いで同期し直せる。revision を最後に進めると、中身だけ変わって
  revision が古いままになり、衝突を検出できない。
- 書き戻す前に `work/state/` の `*.tmp`（rename 前に落ちた書き込みの残骸）を消す。一度 R2 に
  上がると、作業コピーに毎回戻ってくるため。
- `RemoteState#checkout!` は取り出した revision を `work/.state_base_revision` に記録し、
  `push!` で書き戻すと消す。つまりこのファイルがあれば「未完了の実行が残した作業コピー」。
  - 作業コピーがあり、R2 の revision が取得時と同じなら、R2 から取り直さず引き継ぐ
    （`:resumed`）。取り直すと、落ちた実行の `seen_at` 更新が消え、その回の記事が次の回で
    再び新着になるため。
  - 目印ファイルには取り出した実行の owner（episode_key）も残す。別の回の実行が引き継ぐときは、
    落ちた回の確定・履歴記録が次の回の書き戻しに含まれることを警告する。
  - R2 の revision が変わっていれば（別の実行が先に書き戻した）衝突として中断する。
    人が `clean` で手元の作業コピーを破棄してから実行し直す。
  - 生成後・アップロード前と `push!` の直前に revision を再確認し、生成中に別の実行が
    書き戻していた場合も中断する。
  - ただし確認と書き込みはアトミックではない。2 つの実行の書き戻しそのものが重なると、
    後から書いた側が先の側の確定と履歴記録を黙って上書きする。定期実行のリモートと手動の
    手元という想定運用では起きにくいと判断して許容している。
  - `state/` があるのに `state_revision` が無い場合も中断する。revision が無いまま取り出すと、
    以後の比較が R2 の更新有無によらず一致してしまうため。
  - R2 の `state/` が空なら中断する。空の状態から収集すると全記事が新着扱いになり、大量の
    二重紹介になるため。初回は `scripts/seed_remote_state.rb` で手元の状態を置く。
- 音声・公開側の実行は `state/` に触らない。状態を書き換えるのは台本を生成する実行だけ。

### 再生ページの JS（templates/index.html.erb）

- `applyRelativeLabels` は `option` の `data-label`（元のラベル）を基準に毎回テキストを
  組み立て直す。繰り返し呼んでも相対時刻表示が積み上がらない（冪等）。
- `switchToArchive` で src を差し替えた直後にシークバー・時刻表示をいったん 0 に
  リセットするのは、新しい音源の duration が `loadedmetadata` 発火まで確定しないため。
- 再生モード `repeat` は `player.loop = true` を使うため、曲終端で `ended` イベント自体が
  発火しない。連続再生の自動遷移ロジックは `ended` ハンドラにあるが、repeat 時はそこに来ない。
- 連続再生時の `player.play()` の reject を握り潰しているのは、連続再生はユーザーが再生
  ボタンを押した操作の延長で、自動再生ポリシーの reject は通常起きないため。

### 横断的な注意点

- `normalize_link` がスキーム直後の "//" を対象外にする負の後読みを使っているのは、
  "https://" 自体を末尾スラッシュ除去で壊さないため。
- `Episode#now`（収集基準時刻）と `Episode#date`/`date_tag`/`slot`（番組の日付・slot）は
  独立した概念で、混同しないこと。`Pipeline#setup_episode!` は `--date`/`--slot` 指定時も
  `now:` には常に実時刻を渡す。過去日を指定したときに `now` まで過去に飛ばすと、その実行で
  見つかった記事の `seen_at` が過去時刻で記録され、次の回の起点以下として弾かれる。
  `seen_at` は二度と更新されないため、その記事は恒久的に取りこぼされる。

## 移行互換（旧データが消えたら削除）

旧形式のデータを読むために残している処理。本番（R2 の `state/` と公開物）に旧形式が
残っていないことを確かめたら、ここの項目ごとコードを消す。

- **旧・単一ファイルのフィードキャッシュ（`work/state/feed_cache.json`）**:
  `FeedCache` は、まだ一度も fetch していないフィードの新規 entry の seen_at を、この旧台帳に
  その link があれば継承する（URL 別ファイルへ分割したとき、旧来から知っていた記事が一斉に
  新着扱いになるのを防ぐため）。旧台帳は `initialize` で一度だけ読む。
  消してよいかは `scripts/check_legacy_feed_cache.rb` が判定し、削除は人が行う。旧台帳は
  どの link がどのフィード由来か分からないので、「あるフィードが一巡した」だけでは消せない。
  安全条件は `max(旧台帳の全 entry の seen_at) < now - retention_days`（継承しても
  どのみち purge される情報しか残っていない状態）。
- **フィードキャッシュの旧 `"bookmarks"` キー**: `meta_extra` は、extra フィールド導入前の
  形式との互換のため、トップレベルの `"bookmarks"` キーも読む。
- **`last_fetch.json` の旧形式**: 確定履歴導入前の形式（`confirmed_at` だけを持つ）は、
  `confirmed_at` を最古扱いの確定（episode `legacy`）として読み替え、次に書き込むときに
  新しい形式になる。旧形式の `pending_at` は読み捨てる（起点は進まないので、その回の記事は
  次の回で集め直される。取りこぼしより重複の方が安全）。`scripts/seed_remote_state.rb` は
  残っていれば警告する。
- **`work/` 直下の内部状態**: 内部状態を `work/` 直下に置いていた頃の配置は、
  `scripts/seed_remote_state.rb` が `StateDir.migrate_legacy!` で `work/state/` へ移してから
  R2 に置く。
- **収集時刻の無い `news_<key>.txt`**: 収集時刻ファイル（`news_collected_at_<key>.txt`）を
  書く仕組みの導入前に作られた中間ファイルは、確定する時刻が分からないので中断し、
  `clean` で捨てさせる。
- **`pipeline.mode`**: 旧キー `pipeline.mode` は読み替えずにロード時にエラーにする
  （`Config.ensure_no_legacy_keys!`）。dry-struct は未知のキーを黙って捨てるので、そのままだと
  `pipeline.until` 未設定扱いで既定の digest に落ち、publish 環境が気づかないまま止まり続けるため。
- **紹介済み履歴の旧・独立 URL 行**: `strip_links` は、URL がタイトル行に入る前の形式の
  独立した URL 行も除去する。
- **`.used.html` の無い旧フォーマットの回**: 移行前の `.used.txt`（`■` 見出し + `・タイトル` +
  独立 URL 行）の回には `.used.html` が無く、再生ページの JS は `.used.txt` の生表示に
  フォールバックする。この回が retention で公開から外れれば、旧フォーマットを前提にした
  説明は要らない（フォールバック自体は `ok=false` の回のために残す）。
