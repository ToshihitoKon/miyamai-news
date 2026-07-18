# frozen_string_literal: true

require "time"
require "open3"
require "fileutils"
require "tty-spinner"
require_relative "internal/config"
require_relative "internal/template_renderer"
require_relative "internal/hatena_bookmarks"
require_relative "feed_cache"
require_relative "internal/last_fetch_store"

class ScriptGenerator
  # 始めの挨拶。前置き除去の目印にも使う。
  OPENING_GREETING = "宮舞モカです。"

  # フィードの seen_at 履歴を溜める単一ファイル（date/slot 非依存）。
  # 回をまたいで保持する状態なので、last_fetch.json と同じく clean 対象に含めない。
  def self.feed_cache_path(work_dir) = File.join(work_dir, "feed_cache.json")

  # このクラスが work/ に作る回ごとの中間ファイルの glob パターン。
  # clean が消してよいものだけを列挙する（last_fetch.json / feed_cache.json は含めない）。
  def self.work_globs(work_dir)
    %w[news_*.txt script_*.txt tts_script_*.txt]
      .map { |pat| File.join(work_dir, pat) }
  end

  # @param work_dir [String] 中間ファイルの置き場
  # @param episode [Episode] 番組コンテキスト（実行時刻・日付・slot）
  # @param auto_confirm [Boolean] 前回の未確認収集window(pending)を、対話せず自動確定するか。
  #   収集の since を確定する直前(#collect_news)に前回 pending を解決するが、その際 true なら
  #   確認プロンプトを出さず自動確定する（CI等の非対話実行向け）。既定は対話（false）。
  def initialize(work_dir:, episode:, auto_confirm: false)
    @work_dir = work_dir
    @auto_confirm = auto_confirm
    # 収集の時刻演算(since・seen_at・iso8601)には時刻精度のある now を使う。
    @now = episode.now
    @slot = episode.slot
    @date_tag = episode.date_tag
    @today_ja = episode.today_ja
    @greeting_date_ja = episode.greeting_date_ja
    @slot_ja = episode.slot_ja
    @feed_cache = FeedCache.new(
      path: self.class.feed_cache_path(work_dir),
      retention_days:,
      max_retries: fetch_max_retries,
      retry_base_sec: fetch_retry_base_sec
    )
  end

  # ニュースを収集し、AI選別(selector)・facts抽出(extractor)まで進めて止める。
  # pipeline.mode: digest の停止点。facts(ニュース要約)自体が単一ツールとしても
  # 実用的な出力になるよう、selectorの出力(タイトル一覧)より一段先まで進める。
  # 戻り値は facts ファイルのパス。
  def digest
    digest_news
    news_facts_path
  end

  # 台本を生成する。format: false なら人間が読む台本(script)と used まで作って止め、
  # VOICEPEAK 向けの整形(tts_script)は行わない（--script-only 用）。
  # 戻り値は format 済みなら tts_script、未整形なら script のパス。
  #
  # 各ステップ（収集・選定・facts・script+used・整形）はそれぞれ中間ファイルの有無で
  # 再利用を判断し、途中クラッシュ後の再実行で続きから進める。digest 相当のステップは
  # 中間ファイルがあれば再利用されるので、digest 実行後に呼んでも二重に AI を呼ばない。
  def generate(format: true)
    selected_news = digest_news

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

  # この実行で実際に新規のRSS収集（FeedCache#fetch）が発生したか。既存の
  # news_collected_path を再利用しただけなら false。呼び出し側（miyamai_news.rb）が
  # 収集windowを pending 化すべきかどうかの判断に使う。#digest/#generate 実行後にのみ
  # 意味を持つ（呼ぶ前は常に false）。
  def fetched_news? = @fetched_news == true

  # この収集で FeedCache#fetch に渡した基準時刻。新規 entry の seen_at はこの時刻で
  # 記録されるので、次回の収集 window 起点（confirmed_at）にはこれを使う。実行完了時刻
  # (Time.now)ではなく開始時刻を使うのは、実行に時間がかかった場合に seen_at が
  # 開始〜完了の間に刻まれた記事を次回取りこぼさないため。
  def collect_since_anchor = @now

  private

  # --- 設定値 ---

  # 番組編成上のカテゴリ定義（config.yaml の program_details.categories）。
  # label と description のみを持つ。RSS 収集・sources とは完全に無関係
  # （記事がどのカテゴリに属するかは selector が全体を見て判断する）。
  def category_details
    @category_details ||= Config.program_details.categories.map do |c|
      { label: c.label, description: c.description }
    end.freeze
  end

  # 番組全体で紹介するニュースの合計本数の目安（メイン+補欠合計）。カテゴリ単位の
  # 最低保証はない。台本が長くなりすぎるのを防ぐための、選定ステップの AI への指示。
  def total_news_count = Config.program_details.total_news_count

  # RSS 収集元の一覧（フラットな配列）。カテゴリ区分は持たない。
  def sources = Config.rss_feed_sources

  # 前回この mode に到達した記録（confirmed_at）が無い初回に、何時間前までの記事を
  # 拾うかの上限。
  def lookback_hours = Config.collect.lookback_hours

  # FeedCache が entry を保持する日数。フィードに最後に見えた時刻(last_fetched_at)が
  # これより古い（＝フィードから既に消えている）entry だけがパージされる。
  def retention_days = Config.collect.retention_days

  # フィード取得の並列数
  def fetch_threads = Config.collect.fetch_threads

  # フィード取得のリトライ回数と、指数バックオフの初期待機秒数。
  # hnrss などは一時的に 502 を返すことがある。ニュースが揃わないまま
  # 後段の Claude 呼び出しへ進んでトークンを浪費しないよう、
  # リトライし尽くしても取れないソースがあれば実行ごと中断する。
  def fetch_max_retries = Config.collect.fetch_max_retries
  def fetch_retry_base_sec = Config.collect.fetch_retry_base_sec

  def news_collected_path = File.join(@work_dir, "news_#{@date_tag}_#{@slot}.txt")
  def news_selected_path  = File.join(@work_dir, "news_selected_#{@date_tag}_#{@slot}.txt")
  def news_facts_path  = File.join(@work_dir, "news_facts_#{@date_tag}_#{@slot}.txt")
  def script_path      = File.join(@work_dir, "script_#{@date_tag}_#{@slot}.txt")
  def tts_script_path  = File.join(@work_dir, "tts_script_#{@date_tag}_#{@slot}.txt")
  def used_news_path   = File.join(@work_dir, "news_used_#{@date_tag}_#{@slot}.txt")

  # digest（収集→選定→facts抽出）を実行し、facts抽出で使った選定済みニュースの
  # テキストを返す。generate はこの戻り値を使って続きのライター工程に渡す。
  def digest_news
    selected_news = select_news(load_or_collect_news)
    extract_news_facts(selected_news)
    selected_news
  end

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
  # 本体は「■ カテゴリ名」という見出しから始まる構造なので、最初の「■」行を本体の起点とみなす。
  def strip_used_preamble(used)
    lines = used.lines
    start = lines.each_index.find { |i| lines[i].strip.start_with?("■") }
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
    @fetched_news = false

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

  # 収集 window の起点。last_fetch.json の confirmed_at、つまり人間が前回の成果物を
  # 確認して確定させた時点を使う。実行が完了しただけでは進まない（pending_at 止まり）。
  # 前回時刻が無い初回は lookback_hours ぶんさかのぼる（もともと古すぎる記事は対象にしない）。
  def collect_since
    last_fetch_time || (@now - (lookback_hours * 3600))
  end

  # last_fetch.json に記録された、確定済みの収集window起点。無い/壊れていれば nil。
  def last_fetch_time = LastFetchStore.confirmed_at(@work_dir)

  # FeedCache から since 以降に「初めて登場した」記事を集め、フラットなテキストにする。
  # 掲載日時ではなく登場時刻(seen_at)で拾うので、昔書かれて今話題化した記事も取れる。
  # ここでは件数の絞り込みは行わない（全候補を選定ステップの AI に渡すため）。
  # カテゴリ区分は持たない（カテゴリへの分類は selector 段階の AI が行う）。
  # dedup のみ行い、seen_at/priority は選定 AI の判断材料として残す。
  def collect_news
    # since を確定する直前に前回 pending を解決する（確定して since を進めるか／
    # ロールバックして据え置くか）。ここは実際に新規収集が走るときにしか通らないので、
    # 既存スナップショット再利用の実行では確認が出ない。対話込みの解決は LastFetchStore に任せ、
    # ここは「収集の直前」というタイミングを与えるだけ。
    LastFetchStore.resolve_pending!(work_dir: @work_dir, auto_confirm: @auto_confirm)

    since = collect_since
    items_per_source = fetch_sources_in_parallel(sources, since)
    items = dedup_by_title(items_per_source.flatten)

    render_news_text(items)
  rescue FeedCache::FetchError => e
    # 不完全なニュースのまま Claude 呼び出し（トークン消費）へ進まないよう、ここで止める
    abort "aborting, news collection incomplete: #{e.message}"
  end

  # 候補一覧をプレーンテキストにする。この段階では選定ステップの AI にしか
  # 渡らないので、JSON にする必要はない（機械的にパースしない前提なら、フィールド名を
  # 毎エントリ繰り返さないぶんトークンも少なく済む）。カテゴリ見出しは付けない
  # （分類は selector が行う）。
  def render_news_text(items)
    items.each_with_index.map { |item, i| render_news_item(i + 1, item) }.join("\n")
  end

  # 候補ニュース1件分を「タイトル / link / メタ情報」の3行にする。
  def render_news_item(index, item)
    meta = [item[:date], "seen:#{item[:seen_at]}", item[:source]]
    meta << "bookmarks:#{item[:bookmarks]}" if item[:bookmarks]
    meta << "priority:#{item[:priority]}" if item[:priority]
    "#{index}. #{item[:title]}\n   #{item[:link]}\n   (#{meta.join(" / ")})"
  end

  # 全ソースを fetch_threads 並列で収集する。戻り値は sources と同じ順の items 配列。
  # FeedCache はソース単位の fetch を並列に呼んでよい（内部でキャッシュ更新を直列化する）。
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
          warn "collecting: #{src.name}"
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

  # 1ソース分の新着記事を FeedCache から全件取得し、ソース名などのメタ情報を付けて返す。
  # 件数の絞り込みはここでは行わない（選定ステップの AI がタイトルから選ぶ）。
  #
  # HatenaBookmarks は全ソースに無条件で適用する。はてブ以外のフィードには
  # hatena:bookmarkcount が無いので、何も付与せず素通りするだけ（安全）。
  def collect_source(src, since)
    items = @feed_cache.fetch(src.urls || src.url, now: @now, since: since,
      extra_extractor: Internal::HatenaBookmarks)

    items.map do |item|
      picked = { title: item[:title], link: item[:link], date: item[:date],
                 source: src.name, seen_at: item[:seen_at] }
      picked[:bookmarks] = Internal::HatenaBookmarks.count_of(item[:extra]) if item[:extra]
      # 優先度付きソースの記事に印を付け、選定・ライターの取捨選択に使わせる
      picked[:priority] = src.priority if src.priority
      picked
    end
  end

  # --- AI CLI 実行 ---

  # 設定された AI CLI を実行する。claude_extra_args（--allowedTools 等）は claude 固有の
  # 引数なので、bin が claude のときだけ渡す。
  def run_ai_cli(spinner_message, prompt, *claude_extra_args, model_override: nil)
    bin = Config.ai_agent.bin
    model = model_override || Config.ai_agent.model

    if bin == "claude"
      effort = Config.ai_agent.effort
      # effort 未設定なら --effort 自体を渡さず、claude CLI 側の既定に任せる。
      effort_args = effort ? ["--effort", effort] : []
      run_command_with_spinner(
        "#{spinner_message} [#{bin}]",
        "AI CLI failed",
        bin, "-p", "--model", model, *effort_args,
        *claude_extra_args,
        stdin_data: prompt
      )
    else
      run_command_with_spinner(
        "#{spinner_message} [#{bin}]",
        "AI CLI failed",
        bin, "--model", model, "--dangerously-skip-permissions", "-p", prompt
      )
    end
  end

  def get_model_for_role(role)
    Config.ai_agent.model_for(role)
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

  # ニュース選定用タスク。全候補（フラット）のニュース一覧を差し込み、番組全体の
  # 合計目安件数と、カテゴリの分類観点（label+description）、選定結果の書き込み先
  # パスを渡す。ソース単位の絞り込みはせず、priority を判断材料として選定 AI に渡す
  # （面白い記事はソースを問わず採用する方針のため）。
  def selector_prompt(collected_news)
    TemplateRenderer.render("selector.prompt", self,
      collected_news:,
      today_ja: @today_ja,
      category_details:,
      total_news_count:,
      news_selected_path: File.expand_path(news_selected_path))
  end

  # ニュース抽出用タスク。選定済みニュースを差し込み、ファクトシートの書き込み先パスを渡す。
  def extractor_prompt(selected_news)
    TemplateRenderer.render("extractor.prompt", self,
      selected_news:,
      today_ja: @today_ja,
      category_details:,
      total_news_count:,
      news_facts_path: File.expand_path(news_facts_path))
  end

  # ライター用タスク。ファクトシートと選定済みニュースを差し込み、台本(script)と used の書き込み先パスを
  # 渡す（Claude が Write で直接書く）。パスは Claude の cwd に依存しないよう絶対パス。
  # category_details は番組構成の意図（各カテゴリの description）と、used_news の
  # カテゴリ見出しに使う正式なラベル一覧の両方を兼ねる。
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
