# frozen_string_literal: true

require "time"
require "fileutils"
require_relative "internal/config"
require_relative "internal/template_renderer"
require_relative "internal/hatena_bookmarks"
require_relative "feed_cache"
require_relative "internal/last_fetch_store"
require_relative "internal/used_news_history"
require_relative "internal/ai_cli"

class ScriptGenerator
  # 始めの挨拶。前置き除去の目印にも使う。
  OPENING_GREETING = "宮舞モカです。"

  # フィードの seen_at 履歴を URL ごとに保持するディレクトリ（date/slot 非依存、clean 非対象）。
  def self.feed_cache_dir(work_dir) = File.join(work_dir, "feed_cache")

  # 旧・単一ファイル形式のキャッシュ。URL 別ファイルへの移行期に seen_at の継承元として
  # 読むだけで、書き換えはしない（scripts/check_legacy_feed_cache.rb で削除可否を判定できる）。
  def self.legacy_feed_cache_path(work_dir) = File.join(work_dir, "feed_cache.json")

  # work/ に作る回ごとの中間ファイルの glob パターン（clean 対象のみ）。
  def self.work_globs(work_dir)
    %w[news_*.txt script_*.txt tts_script_*.txt]
      .map { |pat| File.join(work_dir, pat) }
  end

  # episode_key（"<date_tag>_<slot>"）から used_news 中間ファイルのパスを組み立てる。
  # 紹介済みニュース履歴の追記が、ScriptGenerator インスタンスを持たない confirm 経路
  # からも同じ命名でこのファイルを引けるようにする。
  def self.used_news_path(work_dir, episode_key) = File.join(work_dir, "news_used_#{episode_key}.txt")

  # episode_key の回の used_news を紹介済みニュース履歴へ追記する（収集window の confirm
  # 時に呼ぶ）。ScriptGenerator インスタンスを持たない経路（publish_only / confirm_fetch）
  # でも episode_key さえあれば同じ命名規則で used ファイルを引ける。episode_key が nil
  # （confirm していない）なら何もしない。詳細は CLAUDE.md 参照。
  def self.record_used_news_history!(work_dir:, episode_key:)
    return unless episode_key

    UsedNewsHistory.record!(
      work_dir: work_dir, episode_key: episode_key,
      used_news_path: used_news_path(work_dir, episode_key),
      keep_episodes: Config.collect.used_news_history_episodes
    )
  end

  # @param work_dir [String] 中間ファイルの置き場
  # @param episode [Episode] 番組コンテキスト（実行時刻・日付・slot）
  # @param auto_confirm [Boolean] 前回の未確認収集windowを対話せず自動確定するか
  #   （CI等の非対話実行向け。既定は対話）
  def initialize(work_dir:, episode:, auto_confirm: false)
    @work_dir = work_dir
    @auto_confirm = auto_confirm
    # 新規収集が起きたら true にする（fetched_news? 参照）。
    @fetched_news = false
    @now = episode.now
    @slot = episode.slot
    @date_tag = episode.date_tag
    @today_ja = episode.today_ja
    @greeting_date_ja = episode.greeting_date_ja
    @slot_ja = episode.slot_ja
    @feed_cache = FeedCache.new(
      dir: self.class.feed_cache_dir(work_dir),
      legacy_path: self.class.legacy_feed_cache_path(work_dir),
      retention_days:,
      skip_window_sec: fetch_skip_minutes * 60,
      max_retries: fetch_max_retries,
      retry_base_sec: fetch_retry_base_sec
    )
  end

  # ニュースを収集し、選定・facts 抽出まで進めて止める（pipeline.mode: digest 相当）。
  # 戻り値は facts ファイルのパス。
  def digest
    digest_news
    news_facts_path
  end

  # 台本を生成する。format: false なら script/used まで作って止める（--script-only 用）。
  # 各ステップは中間ファイルの有無で再利用を判断し、途中クラッシュ後の再実行や
  # digest 実行後の呼び出しでも AI を二重に呼ばない。
  def generate(format: true)
    selected_news = digest_news

    write_script_and_used(selected_news)

    return script_path unless format

    format_tts_script

    tts_script_path
  end

  # --script-only の確認・手直し対象。
  def script_file = script_path

  # 成果物として書き出す used_news。
  def used_news_file = used_news_path

  # この実行で一度でも新規の RSS 収集が発生したか。呼び出し側(miyamai_news.rb)が
  # 収集windowを pending 化すべきか判断するのに使う。一度 true になったら false に
  # 戻らない（詳細は CLAUDE.md 参照）。
  def fetched_news? = @fetched_news == true

  # この収集の基準時刻。次回の収集window起点（confirmed_at）にはこれを使う
  # （実行完了時刻ではなく開始時刻。詳細は CLAUDE.md 参照）。
  def collect_since_anchor = @now

  # この回を一意に指すキー（"<date_tag>_<slot>"）。中間ファイル名・収集window の
  # pending_episode・紹介済みニュース履歴で同じ回を指すのに使う。
  def episode_key = "#{@date_tag}_#{@slot}"

  # episode_key の回の used_news を紹介済みニュース履歴へ追記する（収集window の confirm
  # 時に呼ぶ）。episode_key が nil（confirm していない）なら何もしない。詳細は CLAUDE.md 参照。
  def record_used_news_history!(episode_key)
    self.class.record_used_news_history!(work_dir: @work_dir, episode_key: episode_key)
  end

  private

  # --- 設定値 ---

  # 番組編成上のカテゴリ定義（label + description）。RSS 収集・sources とは無関係
  # （カテゴリ分類は selector が全体を見て判断する）。
  def category_details
    @category_details ||= Config.program_details.categories.map do |c|
      { label: c.label, description: c.description }
    end.freeze
  end

  # 番組全体で紹介するニュース本数の目安（カテゴリ単位の最低保証はない）。
  def total_news_count = Config.program_details.total_news_count

  def sources = Config.rss_feed_sources

  # confirmed_at が無い初回に、何時間前までの記事を拾うかの上限。
  def lookback_hours = Config.collect.lookback_hours

  # FeedCache が entry を保持する日数（last_fetched_at 基準。詳細は CLAUDE.md 参照）。
  def retention_days = Config.collect.retention_days

  def fetch_threads = Config.collect.fetch_threads

  # フィード取得のリトライ回数と、指数バックオフの初期待機秒数。
  def fetch_max_retries = Config.collect.fetch_max_retries
  def fetch_retry_base_sec = Config.collect.fetch_retry_base_sec

  # 各フィードの最終 fetch からこの分数以内は再取得をスキップする。
  def fetch_skip_minutes = Config.collect.fetch_skip_minutes

  # 直近この回数分の紹介済みニュースを selector に渡す（回またぎの重複紹介を避ける）。
  def used_news_history_episodes = Config.collect.used_news_history_episodes

  def news_collected_path = File.join(@work_dir, "news_#{@date_tag}_#{@slot}.txt")
  def news_selected_path  = File.join(@work_dir, "news_selected_#{@date_tag}_#{@slot}.txt")
  def news_facts_path  = File.join(@work_dir, "news_facts_#{@date_tag}_#{@slot}.txt")
  def script_path      = File.join(@work_dir, "script_#{@date_tag}_#{@slot}.txt")
  def tts_script_path  = File.join(@work_dir, "tts_script_#{@date_tag}_#{@slot}.txt")
  # used_news のファイル名規則はクラスメソッドに集約する（confirm 経路が episode_key
  # からパスを再構成できるようにするため。詳細は CLAUDE.md 参照）。
  def used_news_path   = self.class.used_news_path(@work_dir, episode_key)

  # digest（収集→選定→facts抽出）を実行し、facts抽出で使った選定済みニュースの
  # テキストを返す。generate はこの戻り値を使って続きのライター工程に渡す。
  def digest_news
    selected_news = select_news(load_or_collect_news)
    extract_news_facts(selected_news)
    selected_news
  end

  # ニュース選定。全候補からタイトルだけを見て AI に選ばせ、Markdown のまま書かせる。
  # 以降の facts 抽出・執筆はこの選定済みテキストを読む。
  def select_news(collected_news)
    if File.exist?(news_selected_path)
      warn "reuse: #{news_selected_path}"
      return File.read(news_selected_path)
    end

    selector_model = Internal::AiCli.model_for(:selector)
    Internal::AiCli.run("selecting news", selector_prompt(collected_news), model_override: selector_model)

    rewrite_file(news_selected_path) { |text| strip_facts_preamble(text) }
    warn "news (selected): #{news_selected_path}"
    File.read(news_selected_path)
  end

  # ニュース抽出・整理。1 回の AI 呼び出しでニュース内容を抽出して facts.txt に書く。
  def extract_news_facts(selected_news)
    if File.exist?(news_facts_path)
      warn "reuse: #{news_facts_path}"
      return
    end

    extractor_model = Internal::AiCli.model_for(:extractor)
    Internal::AiCli.run("extracting news facts", extractor_prompt(selected_news), model_override: extractor_model)

    rewrite_file(news_facts_path) { |text| strip_facts_preamble(text) }
    warn "news facts: #{news_facts_path}"

    # extractor には facts と一緒に暫定 used_news も書かせる（digest mode でも紹介済み
    # ニュース履歴の元データを残すため。詳細は CLAUDE.md 参照）。writer 到達時は同じパスへ
    # 確定版が上書きされる。履歴用の副産物なので、書かれていなくても digest は止めない。
    finalize_optional_used_news
  end

  # extractor が書いた暫定 used_news があれば知らせる。無ければ何もしない。
  # フォーマットの検証・整形はしない（ScriptGenerator の責務ではない。Publisher が
  # publish 時に UsedNewsFormatter 経由で保証する。CLAUDE.md 参照）。
  def finalize_optional_used_news
    return unless File.exist?(used_news_path)

    warn "used news (provisional): #{used_news_path}"
  end

  # ライター。1 回の AI 呼び出しで script.txt と used.txt を書かせる。既に抽出された
  # facts をもとに執筆するため、WebFetch は許可しない（手戻り防止）。
  def write_script_and_used(selected_news)
    if File.exist?(script_path) && File.exist?(used_news_path)
      warn "reuse: #{script_path}"
      return
    end

    writer_model = Internal::AiCli.model_for(:writer)
    news_facts = File.read(news_facts_path)
    Internal::AiCli.run("writing script and used news",
      writer_prompt(selected_news, news_facts), model_override: writer_model)

    rewrite_file(script_path) { |text| strip_preamble(text) }
    # used_news は writer が書いていなければ止める（不完全なまま後段へ進ませない）。
    # フォーマットの検証・整形はしない（Publisher が publish 時に保証する。CLAUDE.md 参照）。
    abort "expected file not written: #{used_news_path}" unless File.exist?(used_news_path)
    warn "script: #{script_path}"
    warn "used news: #{used_news_path}"
  end

  # 整形。script.txt を読んで VOICEPEAK 向けの tts_script.txt に整形させる。
  def format_tts_script
    if File.exist?(tts_script_path)
      warn "reuse: #{tts_script_path}"
      return
    end

    formatter_model = Internal::AiCli.model_for(:formatter)
    Internal::AiCli.run("formatting for VOICEPEAK", format_prompt, model_override: formatter_model)

    rewrite_file(tts_script_path) { |text| strip_preamble(text) }
    warn "tts script: #{tts_script_path}"
  end

  # AI 出力の前置き（「整形しました」等）を、本体の開始位置（ブロックが返す文字列
  # index）を境に切り落とす。開始位置が見つからなければ原文をそのまま返す
  # （前置き禁止を指示しても稀に混入するため、機械的に確実に落とす。詳細は CLAUDE.md 参照）。
  def strip_preamble_before(text)
    idx = yield(text)
    return text unless idx

    "#{text[idx..].strip}\n"
  end

  def strip_facts_preamble(text)
    strip_preamble_before(text) do |t|
      lines = t.lines
      start = lines.each_index.find { |i| lines[i].strip.start_with?("##", "---", "#") }
      start && lines[...start].join.length
    end
  end

  # Claude が Write で書いたファイルを読み直し、後処理をかけて上書きする。
  # Claude が想定パスに書いていなければ止める（不完全なまま後段へ進ませない）。
  def rewrite_file(path)
    abort "expected file not written: #{path}" unless File.exist?(path)

    File.write(path, yield(File.read(path)))
  end

  # --- ニュース収集 ---

  # 全候補のニュース一覧（選定ステップへの入力）を返す。news_*.txt にスナップショット
  # として残し、あれば再利用する（台本を作り直すとき収集入力を固定するため）。
  def load_or_collect_news
    if File.exist?(news_collected_path)
      warn "reuse: #{news_collected_path}"
      return File.read(news_collected_path)
    end

    @fetched_news = true
    news_body = collect_news
    File.write(news_collected_path, news_body)
    warn "news: #{news_collected_path}"
    news_body
  end

  # 収集 window の起点。前回時刻が無い初回は lookback_hours ぶんさかのぼる。
  def collect_since
    last_fetch_time || (@now - (lookback_hours * 3600))
  end

  # last_fetch.json に記録された、確定済みの収集window起点。無い/壊れていれば nil。
  def last_fetch_time = LastFetchStore.confirmed_at(@work_dir)

  # FeedCache から since 以降に初登場した記事を集め、フラットなテキストにする。
  # 件数の絞り込みは行わない（選定ステップの AI に全候補を渡す）。
  def collect_news
    # since を確定する直前に前回 pending を解決する（呼ぶタイミングはここが握る）。
    # confirm された回は、この回の selector が参照できるよう紹介済みニュース履歴へ追記する
    # （追記対象は「前回確定した回」であって実行中の回ではないので自回は弾かない）。
    confirmed_episode = LastFetchStore.resolve_pending!(work_dir: @work_dir, auto_confirm: @auto_confirm)
    record_used_news_history!(confirmed_episode)

    since = collect_since
    items_per_source = fetch_sources_in_parallel(sources, since)
    items = dedup_by_title(items_per_source.flatten)

    render_news_text(items)
  rescue FeedCache::FetchError => e
    # 不完全なニュースのまま Claude 呼び出し（トークン消費）へ進まないよう、ここで止める
    abort "aborting, news collection incomplete: #{e.message}"
  end

  # 候補一覧をプレーンテキストにする（選定 AI にしか渡らないので JSON 化しない）。
  # カテゴリ見出しは付けない（分類は selector が行う）。
  def render_news_text(items)
    items.each_with_index.map { |item, i| render_news_item(i + 1, item) }.join("\n")
  end

  def render_news_item(index, item)
    meta = [item[:date], "seen:#{item[:seen_at]}", item[:source]]
    meta << "bookmarks:#{item[:bookmarks]}" if item[:bookmarks]
    meta << "priority:#{item[:priority]}" if item[:priority]
    "#{index}. #{item[:title]}\n   #{item[:link]}\n   (#{meta.join(" / ")})"
  end

  # 全ソースを fetch_threads 並列で収集する（FeedCache はソース単位の並列呼び出しに
  # 対応済み）。戻り値は sources と同じ順の items 配列。
  def fetch_sources_in_parallel(sources, since)
    queue = Queue.new
    sources.each_with_index { |src, i| queue << [src, i] }
    queue.close

    items_per_source = Array.new(sources.size)
    workers = fetch_threads.times.map do
      Thread.new do
        # 取得失敗（FetchError）は join 時に呼び出し元へ再送出して中断メッセージに
        # 変換するので、スレッド自身の生バックトレース出力は抑制する
        Thread.current.report_on_exception = false
        while (job = queue.pop)
          src, i = job
          # 進捗ログ（fetched/skipped: <url>）は FeedCache が出す。並列実行で行が混ざらない
          # よう 1 行完結にしてあるので、ここではソース単位の見出しを別途出さない。
          items_per_source[i] = collect_source(src, since)
        end
      end
    end
    workers.each(&:join)
    items_per_source
  end

  # タイトルの重複除去（大文字小文字・空白を無視。先勝ち）
  def dedup_by_title(items)
    items.uniq { |i| i[:title].downcase.gsub(/\s+/, "") }
  end

  # 1ソース分の新着記事を FeedCache から全件取得し、メタ情報を付けて返す。
  # HatenaBookmarks は全ソースに無条件で適用する（はてブ以外には hatena:bookmarkcount
  # が無いので何も付与せず素通りする）。
  def collect_source(src, since)
    items = @feed_cache.fetch(src.url, now: @now, since: since,
      extra_extractor: Internal::HatenaBookmarks)

    items.map do |item|
      picked = { title: item[:title], link: item[:link], date: item[:date],
                 source: src.name, seen_at: item[:seen_at] }
      picked[:bookmarks] = Internal::HatenaBookmarks.count_of(item[:extra]) if item[:extra]
      picked[:priority] = src.priority if src.priority
      picked
    end
  end

  # 始めの挨拶(OPENING_GREETING)を本体の開始位置とみなして前置きを削ぎ落とす。
  def strip_preamble(script)
    strip_preamble_before(script) { |text| text.index(OPENING_GREETING) }
  end

  # --- プロンプト ---
  # 本文は templates/*.prompt.erb に置き、ここではテンプレートに渡す変数を
  # 用意して描画するだけにする。プロンプトの調整はテンプレート側で完結する。

  # ニュース選定用タスク。全候補・カテゴリの分類観点・合計目安件数・選定結果の
  # 書き込み先パスに加え、直近の紹介済みニュース（回またぎの重複回避用）を渡す。
  def selector_prompt(collected_news)
    TemplateRenderer.render("selector.prompt", self,
      collected_news:,
      today_ja: @today_ja,
      category_details:,
      total_news_count:,
      recently_used: UsedNewsHistory.render_for_prompt(@work_dir, used_news_history_episodes),
      news_selected_path: File.expand_path(news_selected_path))
  end

  # facts に加え、紹介済みニュース履歴の元になる暫定 used_news の書き込み先も渡す
  # （digest mode でも履歴を残すため。writer 到達時は同じパスへ確定版が上書きされる）。
  def extractor_prompt(selected_news)
    TemplateRenderer.render("extractor.prompt", self,
      selected_news:,
      today_ja: @today_ja,
      category_details:,
      total_news_count:,
      news_facts_path: File.expand_path(news_facts_path),
      used_news_path: File.expand_path(used_news_path))
  end

  # ライター用タスク。facts と選定済みニュースを差し込み、台本(script)と used の
  # 書き込み先パスを渡す（Claude が Write で直接書く。絶対パスで渡す）。
  def writer_prompt(selected_news, news_facts)
    TemplateRenderer.render("writer.prompt", self,
      selected_news:,
      news_facts:,
      today_ja: @today_ja,
      greeting_date_ja: @greeting_date_ja,
      slot_ja: @slot_ja,
      category_details:,
      script_path: File.expand_path(script_path),
      used_news_path: File.expand_path(used_news_path))
  end

  # 整形用タスク。読み込む台本(script)と書き込む tts_script のパスを渡す
  # （Claude が Read/Write）。
  def format_prompt
    TemplateRenderer.render("format.prompt", self,
      script_path: File.expand_path(script_path),
      tts_script_path: File.expand_path(tts_script_path))
  end
end
