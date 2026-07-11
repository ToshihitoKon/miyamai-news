# frozen_string_literal: true

require "json"
require "time"
require "open3"
require "fileutils"
require "tty-spinner"
require_relative "config"
require_relative "template_renderer"
require_relative "feed_cache"

class ScriptGenerator
  # 収集元定義。category は台本の番組構成（4本立て）に対応
  SOURCES = {
    ai: [
      { name: "Hacker News (AI)",
        url: "https://hnrss.org/newest?q=AI+OR+LLM+OR+GPT&points=50" },
      { name: "arXiv cs.AI",
        url: "http://export.arxiv.org/rss/cs.AI" },
      { name: "OpenAI Blog",
        url: "https://openai.com/news/rss.xml" },
    ],
    # Claude Code / Devin / Cursor / Antigravity などの AI エージェント・AI コーディングツール。
    # Devin(Cognition) は公式 RSS がないため HN のキーワード検索で拾う。
    ai_agents: [
      { name: "Hacker News (agents)",
        url: "https://hnrss.org/newest?q=%22Claude%20Code%22%20OR%20%22coding%20agent%22%20OR%20Devin%20OR%20Cursor%20OR%20Antigravity&points=30" },
      { name: "Claude Code Releases",
        url: "https://github.com/anthropics/claude-code/releases.atom" },
      { name: "Cursor Changelog",
        url: "https://cursor.com/changelog/rss.xml" },
      { name: "Google AI Blog",
        url: "https://blog.google/innovation-and-ai/technology/ai/rss/" },
      { name: "Simon Willison's Weblog",
        url: "https://simonwillison.net/atom/everything/" },
    ],
    security: [
      { name: "JPCERT/CC",
        url: "https://www.jpcert.or.jp/rss/jpcert.rdf" },
      { name: "JVN",
        url: "https://jvn.jp/rss/jvn.rdf" },
    ],
    engineering: [
      { name: "Publickey",
        url: "https://www.publickey1.jp/atom.xml" },
      { name: "Hacker News (frontpage)",
        url: "https://hnrss.org/frontpage?points=100" },
      { name: "Lobsters",
        url: "https://lobste.rs/rss" },
      { name: "gihyo.jp",
        url: "https://gihyo.jp/feed/rss2" },
      { name: "InfoQ Japan",
        url: "https://www.infoq.com/jp/feed/" },
      { name: "DevelopersIO",
        url: "https://dev.classmethod.jp/feed/" },
      # まとめ系・コミュニティ系は玉石混交かつ流量が多いので優先度を下げる。
      # priority: :low はカテゴリ内の件数枠を一次情報源より後回しにするのと、
      # ライターに「補欠扱い」と伝えるプロンプトの両方に使う。
      # はてブはホットエントリと新着の両フィードを読み、ブクマ数上位だけを採用する
      # （RSS は各30件が上限で、オフセット等のパラメータは効かない）。
      { name: "はてブ テクノロジー",
        urls: ["https://b.hatena.ne.jp/hotentry/it.rss",
               "https://b.hatena.ne.jp/entrylist/it.rss"],
        top_by_bookmarks: 20, priority: :low },
      { name: "Qiita 人気記事",
        url: "https://qiita.com/popular-items/feed.atom", priority: :low, max_items: 10 },
      { name: "Zenn 新着",
        url: "https://zenn.dev/feed", priority: :low, max_items: 10 },
    ],
  }.freeze

  # 何時間前までの記事を拾うかの上限。実際の収集 window は、これと「前回 publish からの
  # 経過時間」の短い方を使う（publish 前に何度作り直しても同じ記事を拾い続けないため）。
  LOOKBACK_HOURS = Config.get("collect.lookback_hours").to_i
  # FeedCache が entry を保持する日数。seen_at がこれより古い entry はパージされる。
  # もともと LOOKBACK_HOURS より前の記事は対象にしないので、それを日数に直した程度でよい。
  RETENTION_DAYS = Config.get("collect.retention_days").to_i
  # 各カテゴリの最大件数（台本が長くなりすぎるのを防ぐ）
  MAX_PER_CATEGORY = Config.get("collect.max_per_category").to_i
  # 1ソースあたりの既定の最大件数。max_items も top_by_bookmarks も指定していない
  # ソースに適用する。掲載日時ではなく登場(seen_at)で拾うようになり、1ソースが 24h 分の
  # 新着を大量に返すため、カテゴリ集約時に流量の多いソースが他を押し出さないよう上限を設ける。
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

  # 収集 window の起点を at で確定する。publish 成功時に呼ぶ。
  # この時刻より後の記事だけが次回の収集対象になる。収集(collect)ではなく publish で
  # 確定するので、publish しないまま何度作り直しても起点が動かず、取りこぼしが出ない。
  def self.record_publish(work_dir:, at:)
    File.write(last_fetch_path(work_dir), at.iso8601)
  end

  # @param work_dir [String] 中間ファイルの置き場
  # @param episode [Episode] 番組コンテキスト（実行時刻・日付・slot）
  def initialize(work_dir:, episode:)
    @work_dir = work_dir
    # 収集の時刻演算(since・seen_at・iso8601)には時刻精度のある now を使う。
    @now = episode.now
    @slot = episode.slot
    @date_tag = episode.date_tag
    @today_ja = episode.today_ja
    @feed_cache = FeedCache.new(
      path: File.join(work_dir, "feed_cache.json"),
      retention_days: RETENTION_DAYS,
      max_retries: FETCH_MAX_RETRIES,
      retry_base_sec: FETCH_RETRY_BASE_SEC
    )
  end

  # 台本テキストのパスを返す。
  #
  # 各ステップ（収集・ドラフト・整形・used 記録）はそれぞれ中間ファイルの有無で
  # 再利用を判断し、途中クラッシュ後の再実行で続きから進める。ここで script の
  # 有無だけを見て丸ごと return してしまうと、整形後・used 生成前に落ちたときに
  # used が永久に作られない（再実行しても save_used_news に到達しない）ため、
  # 早期 return はせず常に全ステップを通す。
  def generate
    news_json = load_or_collect_news

    # ステップ2: 整形（テキスト変換のみなので WebFetch は不要）。
    # 整形済み台本が残っていれば再利用し、Claude 呼び出しをスキップする。
    script = load_or_format_script(news_json)

    # ステップ3: 台本で実際に触れたニュースを JSON から抜き出して記録する
    save_used_news(script, news_json)

    script_path
  end

  # 番組で実際に触れたニュース一覧（used_news）のパス。成果物として書き出す用。
  def used_news_file = used_news_path

  private

  # 整形済み台本を返す。既にあれば再利用し、なければドラフトから整形して書き出す。
  def load_or_format_script(news_json)
    if File.exist?(script_path)
      warn "既存の台本を利用: #{script_path}"
      return File.read(script_path)
    end

    draft = load_or_write_draft(news_json)
    script = strip_preamble(run_claude("formatting for VOICEPEAK", format_prompt(draft)))
    File.write(script_path, script)
    warn "台本を生成: #{script_path}"
    script
  end

  def news_json_path = File.join(@work_dir, "news_#{@date_tag}_#{@slot}.json")
  def draft_path     = File.join(@work_dir, "script_draft_#{@date_tag}_#{@slot}.txt")
  def script_path    = File.join(@work_dir, "script_#{@date_tag}_#{@slot}.txt")
  def used_news_path = File.join(@work_dir, "news_used_#{@date_tag}_#{@slot}.txt")

  def last_fetch_path = self.class.last_fetch_path(@work_dir)

  # ステップ1: ライター（記事本文の取得に WebFetch を使う）。
  # ドラフトが残っていれば再利用し、Claude 呼び出しをスキップする。
  def load_or_write_draft(news_json)
    if File.exist?(draft_path)
      warn "既存のドラフトを利用: #{draft_path}"
      return File.read(draft_path)
    end

    draft = run_claude("writing script", writer_prompt(news_json), "--allowedTools", "WebFetch")
    File.write(draft_path, draft)
    draft
  end

  # 台本で実際に触れたニュースを、収集済み JSON から登場順に抜き出して保存する。
  # 台本は元記事を言い換えているため文字列一致では拾えず、Claude に意味照合させる。
  # 既存ファイルがあれば再実行時に Claude 呼び出しを省いて続きから進める。
  def save_used_news(script, news_json)
    if File.exist?(used_news_path)
      warn "既存の使用ニュース一覧を利用: #{used_news_path}"
      return
    end

    # source を正確な発行元にするため、まとめ系記事のリンク先を Claude が確認できるよう
    # WebFetch を許可する。
    used = strip_used_preamble(
      run_claude("extracting used news", used_news_prompt(script, news_json), "--allowedTools", "WebFetch")
    )
    File.write(used_news_path, used)
    warn "使用ニュースを記録: #{used_news_path}"
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

  # ニュース JSON（Claude に渡す本体部分）を返す。
  #
  # その回に選ばれた entry 集合を news_*.json にスナップショットとして残し、あれば再利用
  # する（台本を作り直すとき収集入力を固定するため）。無ければ FeedCache から集めて作る。
  def load_or_collect_news
    if File.exist?(news_json_path)
      warn "既存のニュースを利用: #{news_json_path}"
      return File.read(news_json_path)
    end

    news_body = collect_news
    File.write(news_json_path, news_body)
    warn "ニュースを保存: #{news_json_path}"
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

  # FeedCache から since 以降に「初めて登場した」記事を集め、カテゴリ別の JSON にする。
  # 掲載日時ではなく登場時刻(seen_at)で拾うので、昔書かれて今話題化した記事も取れる。
  def collect_news
    since = collect_since
    jobs = SOURCES.flat_map { |category, sources| sources.map { |src| [category, src] } }
    items_per_job = fetch_jobs_in_parallel(jobs, since)

    result = SOURCES.keys.to_h { |category| [category, []] }
    jobs.zip(items_per_job) do |(category, _src), items|
      result[category].concat(items)
    end
    # カテゴリ内はタイトル重複を除いたうえで、件数枠(MAX_PER_CATEGORY)を priority 順に
    # 埋める。一次情報源(priority なし)を先に、コミュニティ系(priority: :low)を後ろに置き、
    # 同順内は新しく登場した順(seen_at 降順)。流量の多いコミュニティ系が一次情報源を枠から
    # 押し出さないようにするため。seen_at はソート用の内部情報なので最終出力からは落とす。
    result.transform_values! do |items|
      dedup_by_title(items)
        .sort_by { |i| [source_rank(i), -seen_at_epoch(i)] }
        .first(MAX_PER_CATEGORY)
        .each { |i| i.delete(:seen_at) }
    end

    JSON.pretty_generate(result)
  rescue FeedCache::FetchError => e
    # 不完全なニュースのまま Claude 呼び出し（トークン消費）へ進まないよう、ここで止める
    abort "ニュースが揃わないため中断します: #{e.message}"
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

  # カテゴリ内の件数枠を埋める優先順位。小さいほど先。一次情報源は 0、
  # priority: :low のコミュニティ系は 1。（この経路の entry は収集直後の Ruby ハッシュで、
  # priority はシンボル。JSON 再利用パスはここを通らない）
  def source_rank(item) = item[:priority] == :low ? 1 : 0

  # seen_at（初登場時刻）を数値(epoch 秒)にする。新しい順ソートで -値 を使うため。
  def seen_at_epoch(item) = Time.iso8601(item[:seen_at]).to_f

  # 1ソース分の新着記事を FeedCache から取得し、ソース名などのメタ情報を付けて返す。
  def collect_source(src, since)
    items = @feed_cache.fetch(src[:urls] || src[:url], now: @now, since: since)

    if src[:top_by_bookmarks]
      # はてブ用: ブクマ数の多い順に採用する
      items = items.sort_by { |i| -i[:bookmarks].to_i }.first(src[:top_by_bookmarks])
    else
      # それ以外は、新しく登場した順(seen_at 降順)の上位だけに絞る。
      # max_items 指定があればそれを、なければ既定の上限を使う。
      limit = src[:max_items] || DEFAULT_MAX_PER_SOURCE
      items = items.sort_by { |i| -seen_at_epoch(i) }.first(limit)
    end

    items.map do |item|
      # seen_at はカテゴリ集約時のソートに使う内部情報。最終出力前に collect_news で落とす。
      picked = { title: item[:title], link: item[:link], date: item[:date],
                 source: src[:name], seen_at: item[:seen_at] }
      picked[:bookmarks] = item[:bookmarks] if item[:bookmarks]
      # 優先度付きソースの記事に印を付け、ライターの取捨選択に使わせる
      picked[:priority] = src[:priority] if src[:priority]
      picked
    end
  end

  # --- claude 実行 ---

  # 全ての claude 呼び出しで使うモデルと reasoning effort。品質を揃えるため共通化する。
  CLAUDE_MODEL = Config.get("claude.model")
  CLAUDE_EFFORT = Config.get("claude.effort")

  # claude を OS コマンドとして実行し、標準出力を返す。
  # claude は数十秒かかるため、実行中はスピナーを回して進行中だと分かるようにする。
  def run_claude(spinner_message, prompt, *extra_args)
    spinner = TTY::Spinner.new("[:spinner] #{spinner_message}", format: :dots)
    spinner.auto_spin

    # claude は同期実行で数十秒かかるので、別スレッドで走らせてメインでスピナーを回す
    result = nil
    worker = Thread.new do
      result = Open3.capture3(
        "claude", "-p", "--model", CLAUDE_MODEL, "--effort", CLAUDE_EFFORT,
        *extra_args, stdin_data: prompt
      )
    end
    worker.join

    stdout, stderr, status = result
    unless status.success?
      spinner.error("(failed)")
      warn stderr
      abort "claude の実行に失敗しました (exit #{status.exitstatus})"
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

  # モカのキャラクター設定。ライターの前段に埋め込む部品。
  def moka_prompt = TemplateRenderer.render("moka.prompt", self)

  # ライター用タスク。ニュース JSON とモカ設定を差し込んで完成させる。
  def writer_prompt(news_json)
    TemplateRenderer.render("writer.prompt", self,
      moka: moka_prompt,
      news_json:,
      today_ja: @today_ja)
  end

  # 整形用タスク。ライターの出力(ドラフト)を差し込んで完成させる。
  def format_prompt(draft)
    TemplateRenderer.render("format.prompt", self, draft:)
  end

  # 台本と収集済みニュース JSON を渡し、台本で実際に触れられたニュースだけを
  # JSON から登場順に抜き出させるプロンプト。
  def used_news_prompt(script, news_json)
    TemplateRenderer.render("used_news.prompt", self, script:, news_json:)
  end
end
