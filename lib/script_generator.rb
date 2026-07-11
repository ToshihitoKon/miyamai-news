# frozen_string_literal: true

require "rss"
require "rexml/document"
require "json"
require "net/http"
require "uri"
require "time"
require "open3"
require "tempfile"
require "fileutils"
require "tty-spinner"
require_relative "config"
require_relative "template_renderer"

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
      # まとめ系・コミュニティ系は玉石混交かつ流量が多いので、
      # 件数を絞ったうえで優先度を下げる（priority はライターへの指示に使う）。
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
      { name: "Ruby Releases",
        url: "https://github.com/ruby/ruby/releases.atom" },
      { name: "Go Releases",
        url: "https://github.com/golang/go/releases.atom" },
      { name: "Terraform Releases",
        url: "https://github.com/hashicorp/terraform/releases.atom" },
    ],
  }.freeze

  # 何時間前までの記事を拾うかの上限。実際の収集 window は、これと「前回 publish からの
  # 経過時間」の短い方を使う（publish 前に何度作り直しても同じ記事を拾い続けないため）。
  LOOKBACK_HOURS = Config.get("collect.lookback_hours").to_i
  # 収集済みキャッシュがあるとき、収集した時刻(collected_at)からこの時間以上
  # 経っていれば古いとみなして作り直す。未満なら再利用する。
  RECOLLECT_THRESHOLD_HOURS = Config.get("collect.recollect_threshold_hours").to_f
  # 各カテゴリの最大件数（台本が長くなりすぎるのを防ぐ）
  MAX_PER_CATEGORY = Config.get("collect.max_per_category").to_i
  # フィード取得の並列数
  FETCH_THREADS = Config.get("collect.fetch_threads").to_i
  # フィード取得のリトライ回数と、指数バックオフの初期待機秒数。
  # hnrss などは一時的に 502 を返すことがある。ニュースが揃わないまま
  # 後段の Claude 呼び出しへ進んでトークンを浪費しないよう、
  # リトライし尽くしても取れないソースがあれば実行ごと中断する。
  FETCH_MAX_RETRIES = Config.get("collect.fetch_max_retries").to_i
  FETCH_RETRY_BASE_SEC = Config.get("collect.fetch_retry_base_sec").to_f

  # フィードが取得できなかったことを表す。呼び出し側で実行の中断に使う。
  class FetchError < StandardError; end

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
    # 収集の時刻演算(cutoff・経過時間・iso8601)には時刻精度のある now を使う。
    @now = episode.now
    @slot = episode.slot
    @date_tag = episode.date_tag
    @today_ja = episode.today_ja
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
  # 収集 window の起点は last_fetch.txt（＝前回 publish 時点）で、これは publish 成功
  # 時にしか進まない。よって「まだ publish していない回を作り直す」間は起点が固定され、
  # 破棄→再収集しても前回の window 分を取りこぼさない。
  def load_or_collect_news
    cached = load_cached_news
    return cached if cached

    since = last_fetch_time
    news_body = collect_news(since)
    write_news_cache(news_body, since)
    warn "ニュースを保存: #{news_json_path}"
    news_body
  end

  # キャッシュを再利用してよければその本体(Claude に渡す news 部分)を返す。
  # 作り直すべき、または壊れている場合は nil。
  #
  # 再利用の条件は次の両方:
  # - 収集時の起点(since_datetime)が今の起点(last_fetch)と一致する。publish が挟まって
  #   起点が動いていれば、古い window で集めたキャッシュなので作り直す。
  # - 収集時刻(collected_at)から RECOLLECT_THRESHOLD_HOURS 未満。起点が同じでも古すぎる
  #   キャッシュは新着を取りこぼすので作り直す。
  def load_cached_news
    return nil unless File.exist?(news_json_path)

    cache = JSON.parse(File.read(news_json_path))
    return nil unless cache_window_matches?(cache)
    return nil if cache_stale?(cache)

    warn "既存のニュースを利用: #{news_json_path}"
    JSON.pretty_generate(cache.fetch("news"))
  rescue JSON::ParserError, KeyError
    nil
  end

  def cache_window_matches?(cache)
    cache["since_datetime"] == last_fetch_time&.iso8601
  end

  def cache_stale?(cache)
    collected_at = Time.iso8601(cache["collected_at"])
    stale = (@now - collected_at) >= RECOLLECT_THRESHOLD_HOURS * 3600
    warn "収集から#{RECOLLECT_THRESHOLD_HOURS.to_i}時間以上経過。ニュースを再収集します。" if stale
    stale
  rescue ArgumentError, TypeError
    true
  end

  # 本体を since_datetime / collected_at でくるんでキャッシュに書き出す。
  # Claude に渡すのは news 部分だけなので、メタ情報はここでだけ持つ。
  def write_news_cache(news_body, since)
    cache = {
      "since_datetime" => since&.iso8601,
      "collected_at" => @now.iso8601,
      "news" => JSON.parse(news_body),
    }
    File.write(news_json_path, JSON.pretty_generate(cache))
  end

  # last_fetch.txt に記録された前回 publish 時刻。無い/壊れていれば nil。
  # publish 成功時にのみ更新される（収集 window の起点）。
  def last_fetch_time
    return nil unless File.exist?(last_fetch_path)

    Time.iso8601(File.read(last_fetch_path).strip)
  rescue ArgumentError
    nil
  end

  # 今回の収集で「何時間前までさかのぼるか」。LOOKBACK_HOURS を上限に、前回 publish からの
  # 経過時間があればその短い方を採る。前回時刻が無ければ LOOKBACK_HOURS をそのまま使う。
  def effective_lookback_hours(since)
    return LOOKBACK_HOURS unless since

    elapsed_hours = (@now - since) / 3600.0
    [LOOKBACK_HOURS, elapsed_hours].min
  end

  def collect_news(since = nil)
    cutoff = @now - (effective_lookback_hours(since) * 3600)
    jobs = SOURCES.flat_map { |category, sources| sources.map { |src| [category, src] } }
    items_per_job = fetch_jobs_in_parallel(jobs, cutoff)

    result = SOURCES.keys.to_h { |category| [category, []] }
    jobs.zip(items_per_job) do |(category, _src), items|
      result[category].concat(items)
    end
    result.transform_values! { |items| dedup_by_title(items).first(MAX_PER_CATEGORY) }

    JSON.pretty_generate(result)
  rescue FetchError => e
    # 不完全なニュースのまま Claude 呼び出し（トークン消費）へ進まないよう、ここで止める
    abort "ニュースが揃わないため中断します: #{e.message}"
  end

  # 全ソースを FETCH_THREADS 並列で取得する。戻り値は jobs と同じ順の items 配列。
  # cutoff より古い記事は各ソースの取り込み時に足切りする。
  def fetch_jobs_in_parallel(jobs, cutoff)
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
          items_per_job[i] = collect_source(src, cutoff)
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

  # 1ソース分の記事を取得し、ソース名などのメタ情報を付けて返す。
  def collect_source(src, cutoff)
    bodies = Array(src[:urls] || src[:url]).map { |url| http_get(url) }
    items = bodies.flat_map { |body| extract_items(parse_feed(body), cutoff) }

    if src[:top_by_bookmarks]
      # はてブ用: 全フィードを合わせてブクマ数の多い順に採用する
      items = pick_top_by_bookmarks(items, bodies, src[:top_by_bookmarks])
    elsif src[:max_items]
      # 流量の多いソースはフィード先頭（人気・新着上位）だけに絞る
      items = items.first(src[:max_items])
    end

    items.each do |item|
      item[:source] = src[:name]
      # 優先度付きソースの記事に印を付け、ライターの取捨選択に使わせる
      item[:priority] = src[:priority] if src[:priority]
    end
  end

  # 記事一覧をブクマ数の多い順に limit 件へ絞る。両フィードに同じ記事が
  # 載ることがあるためリンクで重複除去し、採用した記事にはブクマ数を残して
  # ライターが人気の度合いを判断できるようにする。
  def pick_top_by_bookmarks(items, bodies, limit)
    counts = {}
    bodies.each do |body|
      hatena_bookmark_counts(body).each do |link, count|
        counts[link] = [counts[link].to_i, count].max
      end
    end

    items
      .uniq { |i| i[:link] }
      .sort_by { |i| -counts[i[:link]].to_i }
      .first(limit)
      .each { |i| i[:bookmarks] = counts[i[:link]].to_i }
  end

  # はてブ RSS(RDF) から link → ブックマーク数 の対応を作る。
  # rss gem は hatena 名前空間の要素を公開しないため、REXML で直接引く。
  def hatena_bookmark_counts(body)
    doc = REXML::Document.new(body)
    doc.get_elements("//item").to_h do |item|
      [item.elements["link"]&.text.to_s.strip,
       item.elements["hatena:bookmarkcount"]&.text.to_i]
    end
  rescue REXML::ParseException
    {}
  end

  # フィードを取得して本文を返す。失敗時は指数バックオフで FETCH_MAX_RETRIES 回まで
  # 再試行し、それでも取れなければ FetchError を投げる。
  def http_get(url)
    attempt = 0
    begin
      http_get_once(url)
    rescue StandardError => e
      attempt += 1
      raise FetchError, "#{url} の取得に失敗: #{e.message}" if attempt > FETCH_MAX_RETRIES

      wait = FETCH_RETRY_BASE_SEC * (2**(attempt - 1))
      warn "  ! #{url} の取得に失敗（#{attempt}/#{FETCH_MAX_RETRIES} 回目）: #{e.message} / #{wait}秒後に再試行"
      sleep wait
      retry
    end
  end

  def http_get_once(url)
    res = Net::HTTP.get_response(URI.parse(url))
    # GitHub の releases.atom 等は 302 でリダイレクトすることがある
    res = Net::HTTP.get_response(URI.parse(res["location"])) if res.is_a?(Net::HTTPRedirection)
    raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    res.body
  end

  def parse_feed(body)
    RSS::Parser.parse(body, false)
  rescue StandardError => e
    # HTTP は成功しているのに中身が壊れているケース。リトライしても直らないので即中断へ回す
    raise FetchError, "フィードのパースに失敗: #{e.message}"
  end

  def extract_items(feed, cutoff)
    return [] unless feed

    feed.items.filter_map do |item|
      title = item.respond_to?(:title) && item.title or next
      title = title.respond_to?(:content) ? title.content : title.to_s
      link  = item.link.respond_to?(:href) ? item.link.href : item.link.to_s
      date  = item_date(item)

      # 日付が取れないソースは足切りせず通す
      next if date && date < cutoff

      { title: title.strip, link: link.strip, date: date&.iso8601 }
    end
  end

  # RSS 2.0 / RDF / Atom で日付の入り方が違うので吸収する。
  def item_date(item)
    if item.respond_to?(:updated) && item.updated
      item.updated.content
    elsif item.respond_to?(:date) && item.date
      item.date
    elsif item.respond_to?(:pubDate) && item.pubDate
      item.pubDate
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
