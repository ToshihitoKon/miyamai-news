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
require_relative "slot"

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

  # 何時間前までの記事を拾うかの上限。実際の収集 window は、これと「前回収集からの
  # 経過時間」の短い方を使う（1日複数回まわしたとき、同じ記事を毎回拾わないため）。
  LOOKBACK_HOURS = Config.get("collect.lookback_hours").to_i
  # 既存の収集済み JSON があるとき、前回収集からこの時間以上経っていれば
  # 問い合わせず自動で再収集する。未満なら y/n を尋ねる。
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

  # @param work_dir [String] 中間ファイルの置き場
  # @param date [Time] 番組の日付
  # @param slot [String] 時間帯 slot（morning/afternoon/evening）。中間ファイル名に付く
  def initialize(work_dir:, date: Time.now, slot: Slot.for(date))
    @work_dir = work_dir
    @date = date
    @slot = slot
    @date_tag = date.strftime("%Y%m%d")
    @today_ja = date.strftime("%Y年%m月%d日")
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

  # 前回収集の実行時刻を記録する単一ファイル（slot 非依存）。
  # 収集 window の起点と、既存 JSON の再収集判定の両方に使う。
  def last_fetch_path = File.join(@work_dir, "last_fetch.txt")

  # --- ニュース収集 ---

  # 同日の JSON があれば再取得せず、それを返す。
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

    lines[start..].join.strip + "\n"
  end

  def load_or_collect_news
    if File.exist?(news_json_path) && !recollect?
      warn "既存のニュースを利用: #{news_json_path}"
      return File.read(news_json_path)
    end

    # 収集の起点（前回収集時刻）は、collect_news が使うので先に読んでおく。
    # 収集が成功したら現在時刻で更新する。
    since = last_fetch_time
    news_json = collect_news(since)
    File.write(news_json_path, news_json)
    File.write(last_fetch_path, @date.iso8601)
    warn "ニュースを保存: #{news_json_path}"
    news_json
  end

  # 既存 JSON があるときに再収集するか決める。
  # - 前回収集から RECOLLECT_THRESHOLD_HOURS 以上 → 自動で再収集
  # - それ未満、または前回時刻が不明 → y/n を尋ねる（非対話環境では再利用に倒す）
  def recollect?
    since = last_fetch_time
    if since && (@date - since) >= RECOLLECT_THRESHOLD_HOURS * 3600
      warn "前回収集から#{RECOLLECT_THRESHOLD_HOURS.to_i}時間以上経過。ニュースを再収集します。"
      return true
    end

    prompt_recollect
  end

  # 既存 JSON を使い回すか、収集し直すかを対話で尋ねる。
  # 標準入力が端末でない（cron 等）場合は尋ねられないので、既存の再利用に倒す。
  def prompt_recollect
    unless $stdin.tty?
      warn "既存のニュースを利用します（非対話環境のため再収集の確認を省略）: #{news_json_path}"
      return false
    end

    $stderr.print "既存のニュース(#{File.basename(news_json_path)})があります。再収集しますか? [y/N]: "
    $stdin.gets.to_s.strip.downcase.start_with?("y")
  end

  # last_fetch.txt に記録された前回収集時刻。無い/壊れていれば nil。
  def last_fetch_time
    return nil unless File.exist?(last_fetch_path)

    Time.iso8601(File.read(last_fetch_path).strip)
  rescue ArgumentError
    nil
  end

  # 今回の収集で「何時間前までさかのぼるか」。LOOKBACK_HOURS を上限に、前回収集からの
  # 経過時間があればその短い方を採る。前回時刻が無ければ LOOKBACK_HOURS をそのまま使う。
  def effective_lookback_hours(since)
    return LOOKBACK_HOURS unless since

    elapsed_hours = (@date - since) / 3600.0
    [LOOKBACK_HOURS, elapsed_hours].min
  end

  def collect_news(since = nil)
    cutoff = @date - (effective_lookback_hours(since) * 3600)
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

  # タイトルの重複除去（大文字小文字・空白を無視）
  def dedup_by_title(items)
    seen = {}
    items.reject do |i|
      key = i[:title].downcase.gsub(/\s+/, "")
      seen[key] ? true : (seen[key] = true; false)
    end
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

    script[idx..].strip + "\n"
  end

  # --- プロンプト ---
  # 本文は templates/*.prompt.erb に置き、ここではテンプレートに渡す変数を
  # 用意して描画するだけにする。プロンプトの調整はテンプレート側で完結する。

  # モカのキャラクター設定。ライターの前段に埋め込む部品。
  def moka_prompt = TemplateRenderer.render("moka.prompt", binding)

  # ライター用タスク。ニュース JSON とモカ設定を差し込んで完成させる。
  def writer_prompt(news_json)
    moka = moka_prompt
    today_ja = @today_ja
    TemplateRenderer.render("writer.prompt", binding)
  end

  # 整形用タスク。ライターの出力(ドラフト)を差し込んで完成させる。
  def format_prompt(draft)
    TemplateRenderer.render("format.prompt", binding)
  end

  # 台本と収集済みニュース JSON を渡し、台本で実際に触れられたニュースだけを
  # JSON から登場順に抜き出させるプロンプト。
  def used_news_prompt(script, news_json)
    TemplateRenderer.render("used_news.prompt", binding)
  end
end
