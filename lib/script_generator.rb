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
  OPENING_GREETING = "宮舞モカです。"

  def self.feed_cache_dir(work_dir) = File.join(work_dir, "feed_cache")
  def self.legacy_feed_cache_path(work_dir) = File.join(work_dir, "feed_cache.json")

  def self.work_globs(work_dir)
    %w[news_*.txt script_*.txt tts_script_*.txt]
      .map { |pat| File.join(work_dir, pat) }
  end

  def self.used_news_path(work_dir, episode_key) = File.join(work_dir, "news_used_#{episode_key}.txt")

  def self.provisional_used_news_path(work_dir, episode_key) = File.join(work_dir, "news_used_provisional_#{episode_key}.txt")

  def self.record_used_news_history!(work_dir:, episode_key:)
    return unless episode_key

    path = used_news_path(work_dir, episode_key)
    path = provisional_used_news_path(work_dir, episode_key) unless File.exist?(path)

    UsedNewsHistory.record!(
      work_dir: work_dir, episode_key: episode_key,
      used_news_path: path,
      keep_episodes: Config.collect.used_news_history_episodes
    )
  end

  def initialize(work_dir:, episode:, auto_confirm: false)
    @work_dir = work_dir
    @auto_confirm = auto_confirm
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

  # 戻り値は facts ファイルのパス。
  def digest
    digest_news
    news_facts_path
  end

  # format: false なら script/used まで作って止める（--script-only 用）。
  def generate(format: true)
    selected_news = digest_news

    write_script_and_used(selected_news)

    return script_path unless format

    format_tts_script

    tts_script_path
  end

  def script_file = script_path
  def used_news_file = used_news_path
  def fetched_news? = @fetched_news == true
  def collect_since_anchor = @now
  def episode_key = "#{@date_tag}_#{@slot}"

  def record_used_news_history!(episode_key)
    self.class.record_used_news_history!(work_dir: @work_dir, episode_key: episode_key)
  end

  private

  # --- 設定値 ---

  def category_details
    @category_details ||= Config.program_details.categories.map do |c|
      { label: c.label, description: c.description }
    end.freeze
  end

  def total_news_count = Config.program_details.total_news_count
  def sources = Config.rss_feed_sources
  def lookback_hours = Config.collect.lookback_hours
  def retention_days = Config.collect.retention_days
  def fetch_threads = Config.collect.fetch_threads
  def fetch_max_retries = Config.collect.fetch_max_retries
  def fetch_retry_base_sec = Config.collect.fetch_retry_base_sec
  def fetch_skip_minutes = Config.collect.fetch_skip_minutes
  def used_news_history_episodes = Config.collect.used_news_history_episodes

  def news_collected_path = File.join(@work_dir, "news_#{@date_tag}_#{@slot}.txt")
  def news_selected_path  = File.join(@work_dir, "news_selected_#{@date_tag}_#{@slot}.txt")
  def news_facts_path  = File.join(@work_dir, "news_facts_#{@date_tag}_#{@slot}.txt")
  def script_path      = File.join(@work_dir, "script_#{@date_tag}_#{@slot}.txt")
  def tts_script_path  = File.join(@work_dir, "tts_script_#{@date_tag}_#{@slot}.txt")
  def used_news_path   = self.class.used_news_path(@work_dir, episode_key)
  def provisional_used_news_path = self.class.provisional_used_news_path(@work_dir, episode_key)

  def digest_news
    load_or_collect_news
    selected_news = select_news
    extract_news_facts(selected_news)
    selected_news
  end

  def select_news
    if File.exist?(news_selected_path)
      warn "reuse: #{news_selected_path}"
      return File.read(news_selected_path)
    end

    selector_model = Internal::AiCli.model_for(:selector)
    Internal::AiCli.run("selecting news", selector_prompt, model_override: selector_model)

    rewrite_file(news_selected_path) { |text| strip_facts_preamble(text) }
    warn "news (selected): #{news_selected_path}"
    File.read(news_selected_path)
  end

  def extract_news_facts(selected_news)
    if File.exist?(news_facts_path)
      warn "reuse: #{news_facts_path}"
      return
    end

    extractor_model = Internal::AiCli.model_for(:extractor)
    Internal::AiCli.run("extracting news facts", extractor_prompt(selected_news), model_override: extractor_model)

    rewrite_file(news_facts_path) { |text| strip_facts_preamble(text) }
    warn "news facts: #{news_facts_path}"

    finalize_optional_used_news
  end

  def finalize_optional_used_news
    return unless File.exist?(provisional_used_news_path)

    warn "used news (provisional): #{provisional_used_news_path}"
  end

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
    abort "expected file not written: #{used_news_path}" unless File.exist?(used_news_path)
    warn "script: #{script_path}"
    warn "used news: #{used_news_path}"
  end

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
  # index）を境に切り落とす。開始位置が見つからなければ原文をそのまま返す。
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
  # Claude が想定パスに書いていなければ止める。
  def rewrite_file(path)
    abort "expected file not written: #{path}" unless File.exist?(path)

    File.write(path, yield(File.read(path)))
  end

  # --- ニュース収集 ---

  # 全候補のニュース一覧（選定ステップへの入力）を返す。news_*.txt にスナップショット
  # として残し、あれば再利用する。
  def load_or_collect_news
    if File.exist?(news_collected_path)
      warn "reuse: #{news_collected_path}"
      return File.read(news_collected_path)
    end

    @fetched_news = true
    news_body = collect_news
    File.write(news_collected_path, news_body)
    LastFetchStore.mark_pending!(work_dir: @work_dir, at: collect_since_anchor, episode_key:)
    warn "news: #{news_collected_path}"
    news_body
  end

  # 収集 window の起点。前回時刻が無い初回は lookback_hours ぶんさかのぼる。
  def collect_since
    last_fetch_time || (@now - (lookback_hours * 3600))
  end

  def last_fetch_time = LastFetchStore.confirmed_at(@work_dir)

  # FeedCache から since 以降に初登場した記事を集め、フラットなテキストにする。
  def collect_news
    confirmed_episode = LastFetchStore.resolve_pending!(work_dir: @work_dir, auto_confirm: @auto_confirm)
    record_used_news_history!(confirmed_episode)

    since = collect_since
    items_per_source = fetch_sources_in_parallel(sources, since)
    items = dedup_by_title(items_per_source.flatten)

    render_news_text(items)
  rescue FeedCache::FetchError => e
    abort "aborting, news collection incomplete: #{e.message}"
  end

  def render_news_text(items)
    items.each_with_index.map { |item, i| render_news_item(i + 1, item) }.join("\n")
  end

  def render_news_item(index, item)
    meta = [item[:date], "seen:#{item[:seen_at]}", item[:source]]
    meta << "bookmarks:#{item[:bookmarks]}" if item[:bookmarks]
    meta << "priority:#{item[:priority]}" if item[:priority]
    "#{index}. #{item[:title]}\n   #{item[:link]}\n   (#{meta.join(" / ")})"
  end

  # 全ソースを fetch_threads 並列で収集する。戻り値は sources と同じ順の items 配列。
  def fetch_sources_in_parallel(sources, since)
    queue = Queue.new
    sources.each_with_index { |src, i| queue << [src, i] }
    queue.close

    items_per_source = Array.new(sources.size)
    workers = fetch_threads.times.map do
      Thread.new do
        Thread.current.report_on_exception = false
        while (job = queue.pop)
          src, i = job
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

  # ニュース選定用タスク。全候補（AI に Read させるファイルパス）・カテゴリの
  # 分類観点・合計目安件数・選定結果の書き込み先パスに加え、直近の紹介済みニュースを渡す。
  def selector_prompt
    TemplateRenderer.render("selector.prompt", self,
      news_collected_path: File.expand_path(news_collected_path),
      today_ja: @today_ja,
      category_details:,
      total_news_count:,
      recently_used: UsedNewsHistory.render_for_prompt(@work_dir, used_news_history_episodes),
      news_selected_path: File.expand_path(news_selected_path))
  end

  # facts に加え、紹介済みニュース履歴の元になる暫定 used_news の書き込み先も渡す。
  def extractor_prompt(selected_news)
    TemplateRenderer.render("extractor.prompt", self,
      selected_news:,
      today_ja: @today_ja,
      category_details:,
      total_news_count:,
      news_facts_path: File.expand_path(news_facts_path),
      used_news_path: File.expand_path(provisional_used_news_path))
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
