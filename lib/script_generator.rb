# frozen_string_literal: true

require "time"
require "open3"
require "fileutils"
require "tty-spinner"
require_relative "internal/config"
require_relative "internal/template_renderer"
require_relative "internal/hatena_bookmarks"
require_relative "feed_cache"

class ScriptGenerator
  # カテゴリ定義（config.yaml の collect.sources）。台本の番組構成（何本立てか）もこれに従う。
  # YAML 由来の文字列キー/値をコード内で使うシンボルに変換する
  # （category 名、各ソースハッシュのキー、priority の値）。
  CATEGORIES = Config.get("collect.sources").to_h do |category, cfg|
    sources = cfg.fetch("sources").map { |src| src.to_h { |k, v| [k.to_sym, k == "priority" ? v.to_sym : v] } }
    [category.to_sym, { label: cfg.fetch("label", category), sources: sources }]
  end.freeze

  # カテゴリごとのソース一覧だけを取り出したもの。ニュース収集で使う。
  SOURCES = CATEGORIES.transform_values { |cfg| cfg[:sources] }.freeze

  # 何時間前までの記事を拾うかの上限。実際の収集 window は、これと「前回 publish からの
  # 経過時間」の短い方を使う（publish 前に何度作り直しても同じ記事を拾い続けないため）。
  LOOKBACK_HOURS = Config.get("collect.lookback_hours").to_i
  # FeedCache が entry を保持する日数。フィードに最後に見えた時刻(last_fetched_at)が
  # これより古い（＝フィードから既に消えている）entry だけがパージされる。
  RETENTION_DAYS = Config.get("collect.retention_days").to_i
  # 各カテゴリの目安件数（台本が長くなりすぎるのを防ぐ）。Ruby が機械的に足切りするの
  # ではなく、選定ステップの AI への指示に使う。
  MAX_PER_CATEGORY = Config.get("collect.max_per_category").to_i
  # 1ソースあたりの既定の選定目安件数。max_items も top_by_bookmarks も指定していない
  # ソースに適用する。選定ステップの AI への指示に使う（Ruby 側での機械的な足切りには
  # 使わない）。
  DEFAULT_MAX_PER_SOURCE = Config.get("collect.default_max_per_source").to_i
  # フィード取得の並列数
  FETCH_THREADS = Config.get("collect.fetch_threads").to_i
  # フィード取得のリトライ回数と、指数バックオフの初期待機秒数。
  # hnrss などは一時的に 502 を返すことがある。ニュースが揃わないまま
  # 後段の Claude 呼び出しへ進んでトークンを浪費しないよう、
  # リトライし尽くしても取れないソースがあれば実行ごと中断する。
  FETCH_MAX_RETRIES = Config.get("collect.fetch_max_retries").to_i
  FETCH_RETRY_BASE_SEC = Config.get("collect.fetch_retry_base_sec").to_f

  # 始めの挨拶。前置き除去の目印にも使う。
  OPENING_GREETING = "宮舞モカです。"

  # 収集 window の起点を記録する単一ファイル（date/slot 非依存）。
  def self.last_fetch_path(work_dir) = File.join(work_dir, "last_fetch.txt")

  # フィードの seen_at 履歴を溜める単一ファイル（date/slot 非依存）。
  # 回をまたいで保持する状態なので、last_fetch.txt と同じく clean 対象に含めない。
  def self.feed_cache_path(work_dir) = File.join(work_dir, "feed_cache.json")

  # このクラスが work/ に作る回ごとの中間ファイルの glob パターン。
  # clean が消してよいものだけを列挙する（last_fetch.txt / feed_cache.json は含めない）。
  def self.work_globs(work_dir)
    %w[news_*.txt script_*.txt tts_script_*.txt]
      .map { |pat| File.join(work_dir, pat) }
  end

  # 収集 window の起点を at で確定する。publish 成功時に呼ぶ。
  # この時刻より後の記事だけが次回の収集対象になる。収集(collect)ではなく publish で
  # 確定するので、publish しないまま何度作り直しても起点が動かず、取りこぼしが出ない。
  def self.record_publish(work_dir:, at:)
    File.write(last_fetch_path(work_dir), at.iso8601)
  end

  # @param work_dir [String] 中間ファイルの置き場
  # @param episode [Episode] 番組コンテキスト（実行時刻・日付・slot）
  # @param cli [String, Symbol, nil] 使用する AI CLI ツールの指定 ("claude" / "antigravity")
  def initialize(work_dir:, episode:, cli: nil)
    @work_dir = work_dir
    # 収集の時刻演算(since・seen_at・iso8601)には時刻精度のある now を使う。
    @now = episode.now
    @slot = episode.slot
    @date_tag = episode.date_tag
    @today_ja = episode.today_ja
    @cli_type = resolve_cli_type(cli)
    @feed_cache = FeedCache.new(
      path: self.class.feed_cache_path(work_dir),
      retention_days: RETENTION_DAYS,
      max_retries: FETCH_MAX_RETRIES,
      retry_base_sec: FETCH_RETRY_BASE_SEC
    )
  end

  # 台本を生成する。format: false なら人間が読む台本(script)と used まで作って止め、
  # VOICEPEAK 向けの整形(tts_script)は行わない（--script-only 用）。
  # 戻り値は format 済みなら tts_script、未整形なら script のパス。
  #
  # 各ステップ（収集・選定・facts・script+used・整形）はそれぞれ中間ファイルの有無で
  # 再利用を判断し、途中クラッシュ後の再実行で続きから進める。
  def generate(format: true)
    collected_news = load_or_collect_news

    # ステップ1.5: ニュース選定。全候補からソース/カテゴリごとの目安件数を
    # AI がタイトルから選び出す。
    selected_news = select_news(collected_news)

    # ステップ2.1: ニュース抽出・整理（ファクトシート作成）。
    # 1回の AI 呼び出しでニュースURLから WebFetch して要点をまとめる。
    extract_news_facts(selected_news)

    # ステップ2.2: ライター。ファクトシートをもとに台本と used を生成する。
    write_script_and_used(selected_news)

    return script_path unless format

    # ステップ3: VOICEPEAK 向け整形（script → tts_script）。カナ化に集中させるため
    # 別呼び出しにする。tts_script は読み上げ用の一時ファイル。
    format_tts_script

    tts_script_path
  end

  # 人間が読む台本(script)のパス。--script-only の確認・手直し対象。
  def script_file = script_path

  # 音声合成に渡す、VOICEPEAK 向けに整形した台本(tts_script)のパス。
  def tts_script_file = tts_script_path

  # 番組で実際に触れたニュース一覧（used_news）のパス。成果物として書き出す用。
  def used_news_file = used_news_path

  private

  def news_collected_path = File.join(@work_dir, "news_#{@date_tag}_#{@slot}.txt")
  def news_selected_path  = File.join(@work_dir, "news_selected_#{@date_tag}_#{@slot}.txt")
  def news_facts_path  = File.join(@work_dir, "news_facts_#{@date_tag}_#{@slot}.txt")
  def script_path      = File.join(@work_dir, "script_#{@date_tag}_#{@slot}.txt")
  def tts_script_path  = File.join(@work_dir, "tts_script_#{@date_tag}_#{@slot}.txt")
  def used_news_path   = File.join(@work_dir, "news_used_#{@date_tag}_#{@slot}.txt")

  def last_fetch_path = self.class.last_fetch_path(@work_dir)

  # ステップ1.5: ニュース選定。全候補(collected_news)から、ソース/カテゴリごとの目安件数を
  # AI がタイトルだけを見て選び出す。選んだニュースの情報（title/link/date/source等）を
  # そのまま Markdown で書かせ、以降の facts 抽出・執筆はこの選定済みテキストを読む。
  def select_news(collected_news)
    if File.exist?(news_selected_path)
      warn "reuse: #{news_selected_path}"
      return File.read(news_selected_path)
    end

    selector_model = get_model_for_role(:selector)
    run_ai_cli("selecting news",
      selector_prompt(collected_news), "--allowedTools", "Write", model_override: selector_model)

    rewrite_file(news_selected_path) { |text| strip_facts_preamble(text) }
    warn "news (selected): #{news_selected_path}"
    File.read(news_selected_path)
  end

  # ステップ2: ライター。1 回の Claude 呼び出しで script.txt と used.txt を書かせる。
  # Claude が Write で直接書くので、書き込み先の 2 パスをプロンプトで明示する。
  # 出力の前置き・思考メモ混入は Claude 側で防ぎきれないので、書かれたファイルを
  # Ruby が読み直して strip をかけ、上書き保存する。
  # 再開判定は「両方揃って初めてスキップ」。片方でも欠ければ作り直す。
  # ステップ2.1: ニュース抽出・整理。1 回の AI 呼び出しでニュース内容を抽出して facts.txt に書く。
  def extract_news_facts(selected_news)
    if File.exist?(news_facts_path)
      warn "reuse: #{news_facts_path}"
      return
    end

    extractor_model = get_model_for_role(:extractor)
    run_ai_cli("extracting news facts",
      extractor_prompt(selected_news), "--allowedTools", "WebFetch Write", model_override: extractor_model)

    rewrite_file(news_facts_path) { |text| strip_facts_preamble(text) }
    warn "news facts: #{news_facts_path}"
  end

  # ステップ2.2: ライター。1 回の AI 呼び出しで script.txt と used.txt を書かせる。
  # すでに抽出されたファクトをもとに執筆するため、WebFetch は許可しない（手戻り防止）。
  def write_script_and_used(selected_news)
    if File.exist?(script_path) && File.exist?(used_news_path)
      warn "reuse: #{script_path}"
      return
    end

    writer_model = get_model_for_role(:writer)
    news_facts = File.read(news_facts_path)
    run_ai_cli("writing script and used news",
      writer_prompt(selected_news, news_facts), "--allowedTools", "Read Write", model_override: writer_model)

    rewrite_file(script_path) { |text| strip_preamble(text) }
    rewrite_file(used_news_path) { |text| strip_used_preamble(text) }
    warn "script: #{script_path}"
    warn "used news: #{used_news_path}"
  end

  # ステップ3: 整形。script.txt を読んで VOICEPEAK 向けの tts_script.txt に整形させる。
  def format_tts_script
    if File.exist?(tts_script_path)
      warn "reuse: #{tts_script_path}"
      return
    end

    formatter_model = get_model_for_role(:formatter)
    run_ai_cli("formatting for VOICEPEAK", format_prompt, "--allowedTools", "Read Write", model_override: formatter_model)

    rewrite_file(tts_script_path) { |text| strip_preamble(text) }
    warn "tts script: #{tts_script_path}"
  end

  def strip_facts_preamble(text)
    lines = text.lines
    start = lines.each_index.find do |i|
      lines[i].strip.start_with?("##", "---", "#")
    end
    return text.strip unless start

    "#{lines[start..].join.strip}\n"
  end

  # Claude が Write で書いたファイルを読み直し、後処理をかけて上書きする。
  # Claude が想定パスに書いていなければ止める（不完全なまま後段へ進ませない）。
  def rewrite_file(path)
    abort "expected file not written: #{path}" unless File.exist?(path)

    File.write(path, yield(File.read(path)))
  end

  # 一覧本体より前に混入した前置きや照合の思考メモを落とす。
  # プロンプトで禁止しても稀に出るため、機械的に確実に取り除く。
  #
  # 本体は「N.（タイトル）→ 次行が URL」という3行構造なので、単に「1.」で始まる行を
  # 探すのではなく、直後の行が http で始まる「1.」を本体の起点とみなす。
  # 思考メモにも「1. …」のような番号付き解説が混ざることがあり、それを取り違えないため。
  def strip_used_preamble(used)
    lines = used.lines
    start = lines.each_index.find do |i|
      lines[i].match?(/^\s*1\.\s/) && lines[i + 1]&.strip&.start_with?("http")
    end
    # 想定した構造が見つからなければそのまま返して人間が気づけるようにする
    return used unless start

    "#{lines[start..].join.strip}\n"
  end

  # --- ニュース収集 ---

  # 全候補のニュース一覧（選定ステップへの入力）を返す。
  #
  # その回に集まった entry 集合を news_*.txt にスナップショットとして残し、あれば再利用
  # する（台本を作り直すとき収集入力を固定するため）。無ければ FeedCache から集めて作る。
  def load_or_collect_news
    if File.exist?(news_collected_path)
      warn "reuse: #{news_collected_path}"
      return File.read(news_collected_path)
    end

    news_body = collect_news
    File.write(news_collected_path, news_body)
    warn "news: #{news_collected_path}"
    news_body
  end

  # 収集 window の起点。last_fetch.txt（＝前回 publish 時点）を使う。これは publish
  # 成功時にしか進まないので、publish していない回を作り直す間は起点が固定され、破棄→
  # 再収集しても前回の window 分を取りこぼさない。前回時刻が無い初回は LOOKBACK_HOURS
  # ぶんさかのぼる（もともと古すぎる記事は対象にしない）。
  def collect_since
    last_fetch_time || (@now - (LOOKBACK_HOURS * 3600))
  end

  # last_fetch.txt に記録された前回 publish 時刻。無い/壊れていれば nil。
  # publish 成功時にのみ更新される（収集 window の起点）。
  def last_fetch_time
    return nil unless File.exist?(last_fetch_path)

    Time.iso8601(File.read(last_fetch_path).strip)
  rescue ArgumentError
    nil
  end

  # FeedCache から since 以降に「初めて登場した」記事を集め、カテゴリ別のテキストにする。
  # 掲載日時ではなく登場時刻(seen_at)で拾うので、昔書かれて今話題化した記事も取れる。
  # ここでは件数の絞り込みは行わない（全候補を選定ステップの AI に渡すため）。
  # dedup のみ行い、seen_at/priority は選定 AI の判断材料として残す。
  def collect_news
    since = collect_since
    jobs = SOURCES.flat_map { |category, sources| sources.map { |src| [category, src] } }
    items_per_job = fetch_jobs_in_parallel(jobs, since)

    result = SOURCES.keys.to_h { |category| [category, []] }
    jobs.zip(items_per_job) do |(category, _src), items|
      result[category].concat(items)
    end
    result.transform_values! { |items| dedup_by_title(items) }

    render_news_text(result)
  rescue FeedCache::FetchError => e
    # 不完全なニュースのまま Claude 呼び出し（トークン消費）へ進まないよう、ここで止める
    abort "aborting, news collection incomplete: #{e.message}"
  end

  # カテゴリ別の候補一覧をプレーンテキストにする。この段階では選定ステップの AI にしか
  # 渡らないので、JSON にする必要はない（機械的にパースしない前提なら、フィールド名を
  # 毎エントリ繰り返さないぶんトークンも少なく済む）。
  def render_news_text(grouped)
    grouped.filter_map do |category, items|
      next if items.empty?

      lines = items.each_with_index.map { |item, i| render_news_item(i + 1, item) }
      "## #{CATEGORIES[category][:label]}\n#{lines.join("\n")}"
    end.join("\n\n")
  end

  # 候補ニュース1件分を「タイトル / link / メタ情報」の3行にする。
  def render_news_item(index, item)
    meta = [item[:date], "seen:#{item[:seen_at]}", item[:source]]
    meta << "bookmarks:#{item[:bookmarks]}" if item[:bookmarks]
    meta << "priority:#{item[:priority]}" if item[:priority]
    "#{index}. #{item[:title]}\n   #{item[:link]}\n   (#{meta.join(" / ")})"
  end

  # 全ソースを FETCH_THREADS 並列で収集する。戻り値は jobs と同じ順の items 配列。
  # FeedCache はソース単位の fetch を並列に呼んでよい（内部でキャッシュ更新を直列化する）。
  def fetch_jobs_in_parallel(jobs, since)
    queue = Queue.new
    jobs.each_with_index { |(_category, src), i| queue << [src, i] }
    queue.close

    items_per_job = Array.new(jobs.size)
    workers = FETCH_THREADS.times.map do
      Thread.new do
        # 取得失敗（FetchError）は join 時に呼び出し元へ再送出して中断メッセージに
        # 変換するので、スレッド自身の生バックトレース出力は抑制する
        Thread.current.report_on_exception = false
        while (job = queue.pop)
          src, i = job
          warn "collecting: #{src[:name]}"
          items_per_job[i] = collect_source(src, since)
        end
      end
    end
    workers.each(&:join)
    items_per_job
  end

  # タイトルの重複除去（大文字小文字・空白を無視。先勝ち）
  def dedup_by_title(items)
    items.uniq { |i| i[:title].downcase.gsub(/\s+/, "") }
  end

  # 1ソース分の新着記事を FeedCache から全件取得し、ソース名などのメタ情報を付けて返す。
  # 件数の絞り込みはここでは行わない（選定ステップの AI がタイトルから選ぶ）。
  def collect_source(src, since)
    extra_extractor = src[:top_by_bookmarks] ? Internal::HatenaBookmarks : nil
    items = @feed_cache.fetch(src[:urls] || src[:url], now: @now, since: since, extra_extractor: extra_extractor)

    items.map do |item|
      picked = { title: item[:title], link: item[:link], date: item[:date],
                 source: src[:name], seen_at: item[:seen_at] }
      picked[:bookmarks] = Internal::HatenaBookmarks.count_of(item[:extra]) if item[:extra]
      # 優先度付きソースの記事に印を付け、選定・ライターの取捨選択に使わせる
      picked[:priority] = src[:priority] if src[:priority]
      picked
    end
  end

  # --- AI CLI 実行 ---

  def resolve_cli_type(cli_override)
    name = cli_override || Config.get("ai.cli", "claude")
    case name.to_s.downcase.strip
    when "antigravity", "agy"
      :antigravity
    when "claude"
      :claude
    else
      abort "unknown AI CLI: #{name} (use 'claude' or 'antigravity')"
    end
  end

  # 指定された AI CLI (claude または antigravity) を実行する。
  def run_ai_cli(spinner_message, prompt, *claude_extra_args, model_override: nil)
    case @cli_type
    when :claude
      run_claude_cli(spinner_message, prompt, *claude_extra_args, model_override: model_override)
    when :antigravity
      run_antigravity_cli(spinner_message, prompt, model_override: model_override)
    end
  end

  # 既存呼び出しとの互換のためのエイリアス
  alias run_claude run_ai_cli

  def run_claude_cli(spinner_message, prompt, *extra_args, model_override: nil)
    bin = Config.get("claude.bin", "claude")
    model = model_override || Config.get("claude.model", "claude-opus-4-8")
    effort = Config.get("claude.effort", "xhigh")

    run_command_with_spinner(
      "#{spinner_message} [claude]",
      "Claude CLI failed",
      bin, "-p", "--model", model, "--effort", effort,
      *extra_args,
      stdin_data: prompt
    )
  end

  def run_antigravity_cli(spinner_message, prompt, model_override: nil)
    bin = Config.get("antigravity.bin", "agy")
    model = model_override || Config.get("antigravity.model", "gemini-3.1-pro-high")

    run_command_with_spinner(
      "#{spinner_message} [antigravity]",
      "Antigravity CLI failed",
      bin, "--model", model, "--dangerously-skip-permissions", "-p", prompt
    )
  end

  def get_model_for_role(role)
    case @cli_type
    when :antigravity
      case role
      when :selector
        Config.get("antigravity.selector_model", Config.get("antigravity.model", "gemini-3.5-flash-high"))
      when :extractor
        Config.get("antigravity.extractor_model", Config.get("antigravity.model", "gemini-3.1-pro-high"))
      when :writer
        Config.get("antigravity.writer_model", Config.get("antigravity.model", "gemini-3.5-flash-high"))
      when :formatter
        Config.get("antigravity.formatter_model", Config.get("antigravity.model", "gemini-3.5-flash-high"))
      end
    when :claude
      case role
      when :selector
        Config.get("claude.selector_model", Config.get("claude.model", "claude-sonnet-5"))
      when :extractor
        Config.get("claude.extractor_model", Config.get("claude.model", "claude-opus-4-8"))
      when :writer
        Config.get("claude.writer_model", Config.get("claude.model", "claude-3-5-sonnet"))
      when :formatter
        Config.get("claude.formatter_model", Config.get("claude.model", "claude-3-5-sonnet"))
      end
    end
  end

  def run_command_with_spinner(spinner_message, error_message, *cmd, stdin_data: nil)
    spinner = TTY::Spinner.new("[:spinner] #{spinner_message}", format: :dots)
    spinner.auto_spin

    result = nil
    worker = Thread.new do
      opts = stdin_data ? { stdin_data: stdin_data } : {}
      result = Open3.capture3(*cmd, **opts)
    end
    worker.join

    stdout, stderr, status = result
    unless status.success?
      spinner.error("(failed)")
      warn stderr
      abort "#{error_message} (exit #{status.exitstatus})"
    end

    spinner.success("(done)")
    stdout
  end

  # 始めの挨拶より前に残った前置き（「整形しました」等）を削ぎ落とす。
  # プロンプトで前置き禁止を指示しても稀に混入するため、機械的に確実に落とす。
  def strip_preamble(script)
    idx = script.index(OPENING_GREETING)
    # 挨拶が見つからなければ想定外なので、そのまま返して人間が気づけるようにする
    return script unless idx

    "#{script[idx..].strip}\n"
  end

  # --- プロンプト ---
  # 本文は templates/*.prompt.erb に置き、ここではテンプレートに渡す変数を
  # 用意して描画するだけにする。プロンプトの調整はテンプレート側で完結する。

  # ニュース選定用タスク。全候補のニュース一覧を差し込み、ソース/カテゴリごとの
  # 目安件数と、選定結果の書き込み先パスを渡す。
  def selector_prompt(collected_news)
    TemplateRenderer.render("selector.prompt", self,
      collected_news:,
      today_ja: @today_ja,
      source_targets: source_target_lines,
      max_per_category: MAX_PER_CATEGORY,
      news_selected_path: File.expand_path(news_selected_path))
  end

  # ソースごとの選定目安件数（表示名: 件数）の一覧。selector プロンプトに渡す。
  def source_target_lines
    SOURCES.values.flatten.map do |src|
      count = src[:top_by_bookmarks] || src[:max_items] || DEFAULT_MAX_PER_SOURCE
      "#{src[:name]}: #{count}件"
    end
  end

  # ニュース抽出用タスク。選定済みニュースを差し込み、ファクトシートの書き込み先パスを渡す。
  def extractor_prompt(selected_news)
    TemplateRenderer.render("extractor.prompt", self,
      selected_news:,
      today_ja: @today_ja,
      category_labels: CATEGORIES.values.map { |cfg| cfg[:label] },
      news_facts_path: File.expand_path(news_facts_path))
  end

  # ライター用タスク。ファクトシートと選定済みニュースを差し込み、台本(script)と used の書き込み先パスを
  # 渡す（Claude が Write で直接書く）。パスは Claude の cwd に依存しないよう絶対パス。
  def writer_prompt(selected_news, news_facts)
    TemplateRenderer.render("writer.prompt", self,
      selected_news:,
      news_facts:,
      today_ja: @today_ja,
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
