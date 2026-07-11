#!/usr/bin/env ruby
# frozen_string_literal: true

# 宮舞モカのニュース番組を、台本生成から BGM 合成まで一貫して作る。
#
# 処理の流れ:
#   1. ScriptGenerator  … RSS 収集 → ライター → VOICEPEAK 向け整形 で台本テキストを作る
#   2. VoiceSynthesizer … 台本を VOICEPEAK(宮舞モカ) で音声合成し 1 本の mp3 にする
#   3. AudioMixer       … ナレーションに BGM を当てて完成版 mp3 を書き出す
#
# 使い方:
#   ruby miyamai_news.rb [BGMファイル]
#     BGM を省略すると同ディレクトリの既定 BGM を使う。
#
# 一時ファイルは work/ 以下に置く。完成版は dist/miyamai_news_YYYYMMDD.mp3。

require "bundler/inline"

# 単体で完結するよう bundler/inline で依存 gem を取得する。
# Ruby 4.0 で rss/csv/rexml は bundled gem になり、gemfile ブロック内では
# 明示しないと require できない。
gemfile do
  source "https://rubygems.org"
  gem "tty-spinner"
  gem "rss"
  gem "csv"
  gem "rexml"
end

require "rss"
require "rexml/document"
require "json"
require "net/http"
require "uri"
require "time"
require "date"
require "csv"
require "cgi"
require "erb"
require "shellwords"
require "tmpdir"
require "open3"
require "tempfile"
require "fileutils"
require "tty-spinner"
require_relative "config"
require_relative "template_renderer"

# 実行時刻から番組の時間帯 slot を決める。1日に朝・昼・夜と複数回まわしても
# ファイル名が衝突せず、それぞれ別エピソードとして共存できるようにするための区分。
#   morning   = 0:00〜11:59
#   afternoon = 12:00〜17:59
#   evening   = 18:00〜23:59
def slot_for(time)
  case time.hour
  when 0...12  then "morning"
  when 12...18 then "afternoon"
  else "evening"
  end
end

# ---------------------------------------------------------------------------
# 台本生成: RSS 収集 → ライター → VOICEPEAK 向け整形
# ---------------------------------------------------------------------------
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
  def initialize(work_dir:, date: Time.now, slot: slot_for(date))
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

# ---------------------------------------------------------------------------
# 音声合成: 台本を VOICEPEAK(宮舞モカ) で 1 本の mp3 にする
# ---------------------------------------------------------------------------
class VoiceSynthesizer
  VOICEPEAK_BIN = Config.get("voicepeak.bin")
  # ナレーターは宮舞モカで固定。
  NARRATOR = "Miyamai Moca"

  # VOICEPEAK の 1 回あたり合成できる文字数の上限。
  MAX_CHARS = 140

  def initialize(work_dir:, date: Time.now, slot: slot_for(date))
    @work_dir = work_dir
    @slot = slot
    @date_tag = date.strftime("%Y%m%d")
  end

  # 台本テキストを合成し、生成した mp3 のパスを返す。
  def synthesize(script_path)
    abort "VOICEPEAK が見つかりません: #{VOICEPEAK_BIN}" unless File.executable?(VOICEPEAK_BIN)

    chunks = split_chunks(File.read(script_path))
    abort "台本が空です: #{script_path}" if chunks.empty?

    warn "ナレーター: #{NARRATOR} / チャンク数: #{chunks.size}"

    wav_dir = File.join(@work_dir, "wav_#{@date_tag}_#{@slot}")
    FileUtils.mkdir_p(wav_dir)

    wav_paths = chunks.each_with_index.map do |chunk, i|
      path = File.join(wav_dir, format("%04d.wav", i))
      # 前回クラッシュした場合に備え、合成済みの WAV が残っていれば再利用して
      # 続きから再開する（合成完了時に wav_dir ごと消えるので、残存＝未完了分）。
      if File.exist?(path)
        warn "  [#{i + 1}/#{chunks.size}] スキップ（合成済み）"
        next path
      end

      warn "  [#{i + 1}/#{chunks.size}] #{chunk[0, 30]}"
      synthesize_chunk(chunk, path)
      # VOICEPEAK は本来 GUI アプリで、間髪入れず連続起動すると初期化中に
      # クラッシュする。次の起動まで少し間隔を空けて安定させる。
      sleep INTERVAL_SEC
      path
    end

    concat_to_mp3(wav_paths, voice_path)
    FileUtils.rm_rf(wav_dir)

    warn "音声を生成: #{voice_path}"
    voice_path
  end

  private

  def voice_path = File.join(@work_dir, "voice_#{@date_tag}_#{@slot}.mp3")

  # 各チャンク合成後に空ける秒数。VOICEPEAK の連続起動によるクラッシュ避け。
  INTERVAL_SEC = Config.get("voicepeak.interval_sec").to_f

  # 合成失敗時のリトライ回数と、指数バックオフの初期待機秒数。
  # VOICEPEAK はまれに初期化タイミングでクラッシュするため、待機を倍々に
  # 伸ばしながら数回やり直せば大抵は成功する。
  MAX_RETRIES = Config.get("voicepeak.max_retries").to_i
  RETRY_BASE_SEC = Config.get("voicepeak.retry_base_sec").to_f

  # 1チャンクの合成に許す最大秒数。VOICEPEAK はまれに異常終了後もプロセスが
  # 応答を返さずハングすることがあり、放置すると永久にブロックしてしまう。
  # この時間を超えたら kill してリトライへ回す。
  TIMEOUT_SEC = Config.get("voicepeak.timeout_sec").to_f

  # 1チャンク（140文字以内のテキスト）を WAV に合成する。
  # 失敗時は指数バックオフ（RETRY_BASE_SEC * 2**n）で MAX_RETRIES 回まで再試行する。
  def synthesize_chunk(text, out_path)
    attempt = 0
    begin
      run_voicepeak(text, out_path)
    rescue RuntimeError => e
      attempt += 1
      raise if attempt > MAX_RETRIES

      wait = RETRY_BASE_SEC * (2**(attempt - 1))
      warn "    合成に失敗（#{attempt}/#{MAX_RETRIES} 回目）: #{e.message} / #{wait}秒後に再試行"
      sleep wait
      retry
    end
  end

  # VOICEPEAK を 1 回起動して WAV を生成する。失敗・タイムアウト時は RuntimeError を投げる。
  # TIMEOUT_SEC を超えても終了しなければハングとみなし、プロセスグループごと
  # kill してから RuntimeError を投げる（呼び出し元のリトライで再試行される）。
  def run_voicepeak(text, out_path)
    # 新しいプロセスグループで起動し、ハング時に子孫ごとまとめて kill できるようにする。
    stdin, _stdout, stderr, wait_thr = Open3.popen3(
      VOICEPEAK_BIN, "--narrator", NARRATOR, "--say", text, "--out", out_path,
      pgroup: true
    )
    stdin.close
    pgid = Process.getpgid(wait_thr.pid)

    unless wait_thr.join(TIMEOUT_SEC)
      kill_process_group(pgid)
      raise "VOICEPEAK が #{TIMEOUT_SEC}秒以内に応答しませんでした（ハングとみなし kill）"
    end

    status = wait_thr.value
    err = stderr.read
    raise "VOICEPEAK での合成に失敗しました: #{err[-300..]}" unless status.success?
    raise "VOICEPEAK が音声ファイルを生成しませんでした: #{out_path}" unless File.exist?(out_path)
  ensure
    stderr&.close
  end

  # プロセスグループを TERM → （残っていれば）KILL の順で終了させる。
  def kill_process_group(pgid)
    Process.kill("TERM", -pgid)
    # TERM で落ちる猶予を与えてから、まだ生きていれば強制終了する。
    sleep 0.5
    Process.kill("KILL", -pgid)
  rescue Errno::ESRCH
    # 既に終了済み。何もしない。
  end

  # 台本を合成単位のチャンクに分割する。
  # まず「。」で文に切り、140 文字を超える文は句読点でさらに詰め込みながら分割する。
  def split_chunks(script)
    script
      .gsub(/\r\n?/, "\n")
      .split(/(?<=。)/)      # 「。」の直後で分割（句点は各文に残す）
      .map(&:strip)
      .reject(&:empty?)
      .flat_map { |sentence| split_long_sentence(sentence) }
  end

  # 140 文字を超える1文を、読点（、）優先で MAX_CHARS 以内の断片に分ける。
  # 読点でも切れない場合は文字数で強制的に切る。
  def split_long_sentence(sentence)
    return [sentence] if sentence.length <= MAX_CHARS

    chunks = []
    buffer = +""
    sentence.split(/(?<=、)/).each do |part|
      # 読点区切りでも1つが長すぎる場合は文字数で刻む。
      if part.length > MAX_CHARS
        chunks << buffer unless buffer.empty?
        buffer = +""
        part.chars.each_slice(MAX_CHARS) { |slice| chunks << slice.join }
        next
      end

      if (buffer.length + part.length) > MAX_CHARS
        chunks << buffer
        buffer = +""
      end
      buffer << part
    end
    chunks << buffer unless buffer.empty?
    chunks
  end

  # 複数の WAV を ffmpeg の concat demuxer で1本に連結し、mp3 にエンコードする。
  def concat_to_mp3(wav_paths, output)
    list = Tempfile.new(["concat", ".txt"])
    wav_paths.each { |p| list.puts("file '#{p}'") }
    list.close

    _out, err, status = Open3.capture3(
      "ffmpeg", "-y", "-f", "concat", "-safe", "0",
      "-i", list.path, "-c:a", "libmp3lame", "-q:a", "4", output
    )
    raise "ffmpeg での連結に失敗しました: #{err[-300..]}" unless status.success?
  ensure
    list&.unlink
  end
end

# ---------------------------------------------------------------------------
# BGM 合成: ナレーションに BGM を裏で流して完成版 mp3 を書き出す
# ---------------------------------------------------------------------------
#
# 構成:
#   - BGM は 0 秒から再生開始（ナレーションより短ければループ）
#   - ナレーションは INTRO_SEC 秒後に開始
#   - ナレーション終了の TAIL_SEC 秒後から FADE_SEC 秒かけて BGM をフェードアウト
class AudioMixer
  BGM_VOLUME = Config.get("mixer.bgm_volume").to_f
  INTRO_SEC = Config.get("mixer.intro_sec").to_f   # BGM 開始からナレーション開始まで
  TAIL_SEC = Config.get("mixer.tail_sec").to_f     # ナレーション終了からフェードアウト開始まで
  FADE_SEC = Config.get("mixer.fade_sec").to_f     # フェードアウトにかける秒数

  def initialize(bgm_path:)
    @bgm_path = bgm_path
  end

  # ナレーション mp3 に BGM を当てて output_path に書き出す。
  def mix(voice_path, output_path)
    abort "BGM が見つかりません: #{@bgm_path}" unless File.exist?(@bgm_path)

    voice_dur = probe_duration(voice_path)
    fade_start = INTRO_SEC + voice_dur + TAIL_SEC
    total_dur = fade_start + FADE_SEC
    delay_ms = (INTRO_SEC * 1000).to_i

    warn "ナレーション長: #{voice_dur.round(1)}s / BGM音量: #{BGM_VOLUME} / 全体長: #{total_dur.round(1)}s"

    run_mix(voice_path, output_path, fade_start: fade_start, total_dur: total_dur, delay_ms: delay_ms)
    warn "完成版を出力: #{output_path}"
    output_path
  end

  private

  def probe_duration(path)
    out, err, status = Open3.capture3(
      "ffprobe", "-v", "error", "-show_entries", "format=duration",
      "-of", "default=noprint_wrappers=1:nokey=1", path
    )
    raise "ffprobe に失敗しました: #{err[-300..]}" unless status.success?

    out.strip.to_f
  end

  # -stream_loop -1: BGM がナレーションより短くても最後まで途切れないようループ
  # normalize=0: amix の自動音量正規化を無効化し、指定した音量バランスを保つ
  def run_mix(voice_path, output_path, fade_start:, total_dur:, delay_ms:)
    filter = "[0:a]volume=#{BGM_VOLUME},afade=t=out:st=#{fade_start}:d=#{FADE_SEC}[bgm]; " \
             "[1:a]adelay=#{delay_ms}|#{delay_ms}[voice]; " \
             "[bgm][voice]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[out]"

    _out, err, status = Open3.capture3(
      "ffmpeg", "-y",
      "-stream_loop", "-1", "-i", @bgm_path,
      "-i", voice_path,
      "-filter_complex", filter,
      "-map", "[out]", "-t", total_dur.to_s,
      "-c:a", "libmp3lame", "-q:a", "4", output_path
    )
    raise "ffmpeg での BGM 合成に失敗しました: #{err[-300..]}" unless status.success?
  end
end

# ---------------------------------------------------------------------------
# 公開: 生成済み mp3 を GCS に置き、CSV 駆動でペライチ再生ページ(index.html)と
# Atom フィード(feed.xml)を更新する
# ---------------------------------------------------------------------------
#
# 前提:
#   - gcloud が設定済み(認証・プロジェクト)
#   - バケットが公開読み取り可能(または署名URL運用なら別途調整)
#
# GCS 上のレイアウト:
#   gs://<bucket>/miyamai_news_YYYYMMDD[_slot].mp3      … 音声本体
#   gs://<bucket>/miyamai_news_YYYYMMDD[_slot].used.txt … その回で紹介したニュース一覧(任意)
#   gs://<bucket>/archives.csv                          … アーカイブ台帳
#   gs://<bucket>/index.html                            … 再生ページ(毎回再生成)
#   gs://<bucket>/feed.xml                              … Atom フィード(毎回再生成)
#   gs://<bucket>/<cover_image>                         … 横長バナー(事前に手動アップロード)
class Publisher
  PUBLIC_BASE    = Config.get("gcs.public_base")
  DEFAULT_BUCKET = Config.get("gcs.bucket")
  # 横長バナー画像。Slack のリンクプレビューと再生ページの両方で使う。
  # 事前に GCS へアップロードしておく:
  #   gcloud storage cp <cover_image> gs://<bucket>/<cover_image>
  COVER_IMAGE = Config.get("assets.cover_image")

  # ページ/フィードのマークアップは templates/*.erb。埋め込み変数は
  # render_html / render_feed / render_feed_entry のローカル変数を binding 経由で
  # 参照する。値の HTML エスケープは呼び出し側の h() で行い、テンプレートでは素通しする。

  def initialize(bucket: DEFAULT_BUCKET, date: Date.today, title: nil)
    @bucket = bucket
    @date   = date
    @title  = title || "宮舞モカ 技術ニュース #{date.strftime('%Y-%m-%d')}"
  end

  # GCS 上のオブジェクト名は、渡された mp3 のファイル名をそのまま使う
  # （例: miyamai_news_20260710_afternoon.mp3）。日付から組み立て直すと
  # slot が落ちて朝昼夜が同名で上書きし合うため、呼び出し側のファイル名を正とする。
  def run(mp3_path, used_txt_path = nil)
    filename = File.basename(mp3_path)
    used_object = filename.sub(/\.mp3\z/, ".used.txt")

    upload_mp3(mp3_path, filename)
    upload_used_news(used_txt_path, used_object) if used_txt_path
    used_news = used_txt_path && File.exist?(used_txt_path) ? File.read(used_txt_path) : ""
    rows = update_archives(filename, used_news)
    write_index(rows)
    write_feed(rows)

    puts "done: #{public_url('index.html')}"
  end

  private

  def public_url(object)
    "#{PUBLIC_BASE}/#{@bucket}/#{object}"
  end

  def gcloud_storage(*args)
    cmd = ["gcloud", "storage", *args].shelljoin
    system(cmd) || abort("gcloud storage failed: #{cmd}")
  end

  # --- mp3 ---------------------------------------------------------------

  def upload_mp3(local_path, filename)
    abort("mp3 not found: #{local_path}") unless File.exist?(local_path)
    gcloud_storage(
      "cp",
      "--content-type=audio/mpeg",
      "--content-disposition=inline",
      local_path, "gs://#{@bucket}/#{filename}"
    )
  end

  # --- used news ---------------------------------------------------------
  # その回で使用したニュース一覧(AI 生成テキスト)。音声と対にした名前で置く。
  # 中身は解釈せず、再生ページ側でそのまま表示する(URL のみリンク化)。

  def upload_used_news(local_path, object)
    abort("used news not found: #{local_path}") unless File.exist?(local_path)
    gcloud_storage(
      "cp",
      "--content-type=text/plain; charset=utf-8",
      local_path, "gs://#{@bucket}/#{object}"
    )
  end

  # --- archives.csv ------------------------------------------------------
  # 列: date(YYYY-MM-DD), filename, title, used_news, updated_at(RFC3339 UTC)
  # used_news はその回で紹介したニュース一覧の全文(Atom フィードの content 用)。
  # updated_at は生成時刻。当日分を作り直すたびに更新され、Atom の <updated> に
  # 使う。これにより同じ日に再生成しても更新が進み、RSS リーダーが検知できる。
  # 4列目を持たない過去の行は used_news 空、5列目を持たない過去の行は
  # updated_at 空(date の 00:00:00Z にフォールバック)として扱う。
  # 同一 filename は上書き。1日に複数回(朝昼夜)ある場合は date が同じでも
  # filename が異なる行として共存する。降順(新しい順)で保持。

  def update_archives(filename, used_news = "")
    local_csv = File.join(Dir.tmpdir, "miyamai_archives_#{Process.pid}.csv")

    rows = fetch_existing_archives(local_csv)
    # 同じファイル名(=同じ日の同じ時間帯)の回があれば差し替える。
    # 1日に朝昼夜と複数回ある場合、date は同じでも filename が異なるので共存する。
    rows.reject! { |r| r[1] == filename }
    rows << [date_for(filename), filename, @title, used_news, now_rfc3339]
    # 日付(YYYY-MM-DD)を第1キー、生成時刻を第2キーに新しい順で並べる。
    # 同一日に複数回ある場合、生成時刻で slot の前後を安定させる。
    rows.sort_by! { |r| [r[0], r[4].to_s] }
    rows.reverse!

    CSV.open(local_csv, "w") { |csv| rows.each { |r| csv << r } }
    gcloud_storage("cp", "--content-type=text/csv", local_csv, "gs://#{@bucket}/archives.csv")

    rows
  ensure
    File.delete(local_csv) if local_csv && File.exist?(local_csv)
  end

  # 既存 archives.csv を取得する。
  # 「初回でオブジェクトが存在しない」場合のみ空配列で開始し、
  # ネットワーク障害等の取得失敗では abort する。
  # (取得失敗を空扱いすると、既存台帳を空で上書きして全消失させてしまうため)
  def fetch_existing_archives(local_csv)
    return [] unless archives_exist?

    ok = system("gcloud", "storage", "cp", "gs://#{@bucket}/archives.csv", local_csv,
                out: File::NULL, err: File::NULL)
    abort("failed to fetch existing archives.csv (aborting to avoid overwriting the ledger)") unless ok && File.exist?(local_csv)

    CSV.read(local_csv)
  end

  def archives_exist?
    system("gcloud", "storage", "ls", "gs://#{@bucket}/archives.csv",
           out: File::NULL, err: File::NULL)
  end

  # --- index.html --------------------------------------------------------

  def write_index(rows)
    local_html = File.join(Dir.tmpdir, "miyamai_index_#{Process.pid}.html")
    File.write(local_html, render_html(rows))
    gcloud_storage("cp", "--content-type=text/html; charset=utf-8", local_html, "gs://#{@bucket}/index.html")
  ensure
    File.delete(local_html) if local_html && File.exist?(local_html)
  end

  def render_html(rows)
    abort("no archives to render") if rows.empty?

    current = rows.first # 降順なので先頭が最新
    current_url = public_url(current[1])
    page_url = public_url("index.html")
    feed_url = public_url("feed.xml")
    cover_url = public_url(COVER_IMAGE)
    description = "#{date_with_slot(current[0], current[1])} — #{current[2]}"

    options = rows.map { |date, fname, title|
      label = "#{date_with_slot(date, fname)} — #{title}"
      selected = (fname == current[1]) ? " selected" : ""
      %(<option value="#{h(public_url(fname))}"#{selected}>#{h(label)}</option>)
    }.join("\n        ")

    TemplateRenderer.render("index.html", binding)
  end

  # --- feed.xml (Atom) ---------------------------------------------------
  # archives.csv の全エピソードを新しい順のエントリにした Atom フィード。
  # 各エントリの content には、その回で紹介したニュース一覧(used_news)を
  # URL リンク化した HTML で入れる。used_news が無い過去分は content を空にする。

  def write_feed(rows)
    local_xml = File.join(Dir.tmpdir, "miyamai_feed_#{Process.pid}.xml")
    File.write(local_xml, render_feed(rows))
    gcloud_storage("cp", "--content-type=application/atom+xml; charset=utf-8", local_xml, "gs://#{@bucket}/feed.xml")
  ensure
    File.delete(local_xml) if local_xml && File.exist?(local_xml)
  end

  def render_feed(rows)
    abort("no archives to render") if rows.empty?

    feed_url = public_url("feed.xml")
    page_url = public_url("index.html")
    updated  = feed_datetime(rows.first[0], rows.first[4]) # 降順なので先頭が最新

    entries = rows.map { |date, fname, title, used_news, updated_at|
      render_feed_entry(date, fname, title, used_news.to_s, updated_at)
    }.join("\n")

    TemplateRenderer.render("feed.xml", binding)
  end

  def render_feed_entry(date, fname, title, used_news, updated_at)
    # link は読者のクリック先なので再生ページ(index.html)にする。
    # id はエントリの一意識別子なので、回ごとに一意な mp3 URL のままにする
    # (全エントリで同じ index.html を id にすると RSS リーダーが区別できない)。
    entry_id  = public_url(fname)
    entry_url = public_url("index.html")
    updated   = feed_datetime(date, updated_at)
    content   = used_news.strip.empty? ? "" : h(used_news)
    # 同一日に複数回ある場合、entry の title が重複しないよう slot を添える。
    label = slot_label(fname)
    title = "#{title}（#{label}）" unless label.empty?

    TemplateRenderer.render("feed_entry.xml", binding).chomp
  end

  # Atom の <updated> 用 RFC3339 日時を返す。
  # updated_at(生成時刻)があればそれを使う。持たない過去行は date の
  # 00:00:00 UTC にフォールバックする。
  # date の組み立てで Date#to_time を使わないのは、ローカルタイム扱いになり
  # UTC 変換で日付がずれるため。日付文字列をそのまま UTC 午前0時として組む。
  def feed_datetime(date_str, updated_at = nil)
    return updated_at if updated_at && !updated_at.to_s.strip.empty?

    "#{Date.parse(date_str).strftime('%Y-%m-%d')}T00:00:00Z"
  end

  # 現在時刻を UTC の RFC3339 秒精度で返す(例: 2026-07-10T05:11:23Z)。
  def now_rfc3339
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  # ファイル名末尾の slot(_morning/_afternoon/_evening)を日本語ラベルにする。
  # 1日に複数回ある回を UI やフィードで見分けるための表示用。
  # slot を持たない旧ファイル名は空文字を返す(後方互換)。
  SLOT_LABELS = { "morning" => "朝", "afternoon" => "昼", "evening" => "夜" }.freeze

  def slot_label(filename)
    m = filename.match(/_(morning|afternoon|evening)\.mp3\z/)
    m ? SLOT_LABELS.fetch(m[1]) : ""
  end

  # "YYYY-MM-DD" に slot ラベルを添えた表示用の日付。slot が無ければ日付のみ。
  def date_with_slot(date, filename)
    label = slot_label(filename)
    label.empty? ? date : "#{date}（#{label}）"
  end

  # ファイル名(miyamai_news_YYYYMMDD[_slot].mp3)の日付部分を archives.csv 用の
  # "YYYY-MM-DD" にする。GCS のオブジェクト名と同じくファイル名を正とすることで、
  # 過去分を日付指定なしで再アップロードしても date 列が今日にずれない。
  # ファイル名から日付が読めないときだけ @date にフォールバックする。
  def date_for(filename)
    m = filename.match(/(\d{4})(\d{2})(\d{2})/)
    m ? "#{m[1]}-#{m[2]}-#{m[3]}" : @date.to_s
  end

  def h(str)
    CGI.escapeHTML(str.to_s)
  end
end

# ---------------------------------------------------------------------------
# メイン: 台本生成 → 音声合成 → BGM 合成 → 公開 を順に実行
# ---------------------------------------------------------------------------
#
# 使い方:
#   ruby miyamai_news.rb                  台本生成 → 音声合成 → BGM合成 → 公開まで一気通し
#   ruby miyamai_news.rb --generate-only  生成だけ行い dist/ に mp3(+used.txt)を書き出す
#   ruby miyamai_news.rb --publish-only   dist/ の該当回 mp3(+used.txt)を GCS へ公開する
#   ruby miyamai_news.rb --clean          中間生成物(work/)を捨てて終了する
#
#   --bgm PATH   既定 BGM(config の assets.bgm_path)を差し替える
#   --date YYYY-MM-DD / --slot morning|afternoon|evening
#                対象の回を明示する（--publish-only で過去回を公開し直すときなど）

# dist/ に置く成果物のパス。generate と publish で同じ命名規則を共有する。
BASE_DIR = __dir__
WORK_DIR = File.join(BASE_DIR, "work")
DIST_DIR = File.join(BASE_DIR, "dist")

def episode_mp3_path(date_tag, slot)  = File.join(DIST_DIR, "miyamai_news_#{date_tag}_#{slot}.mp3")
def episode_used_path(date_tag, slot) = File.join(DIST_DIR, "miyamai_news_#{date_tag}_#{slot}.used.txt")

def main
  args = parse_args(ARGV)

  if args[:clean]
    clean_work_dir
    return
  end

  date = args[:date] || Time.now
  date_tag = date.strftime("%Y%m%d")
  slot = args[:slot] || slot_for(date)

  FileUtils.mkdir_p(WORK_DIR)
  FileUtils.mkdir_p(DIST_DIR)

  # --publish-only でなければ生成する。
  run_generate(date, date_tag, slot, args[:bgm]) unless args[:publish_only]
  # --generate-only でなければ公開する。
  run_publish(date, date_tag, slot) unless args[:generate_only]
end

# 台本生成 → 音声合成 → BGM 合成。成果物を dist/ に書き出す。
def run_generate(date, date_tag, slot, bgm_override)
  # BGM は config の assets.bgm_path。相対パス指定なら BASE_DIR 起点で解決する。
  bgm_path = bgm_override || File.expand_path(Config.get("assets.bgm_path"), BASE_DIR)
  output_path = episode_mp3_path(date_tag, slot)
  used_news_output = episode_used_path(date_tag, slot)

  generator = ScriptGenerator.new(work_dir: WORK_DIR, date: date, slot: slot)
  script_path = generator.generate
  voice_path = VoiceSynthesizer.new(work_dir: WORK_DIR, date: date, slot: slot).synthesize(script_path)
  AudioMixer.new(bgm_path: bgm_path).mix(voice_path, output_path)

  # 使用ニュース一覧を mp3 と並べて成果物として残す（work/ 側はキャッシュとして温存）。
  FileUtils.cp(generator.used_news_file, used_news_output)

  warn "完成: #{output_path}"
  warn "使用ニュース: #{used_news_output}"
end

# dist/ の該当回 mp3(+used.txt)を GCS へ公開する。
def run_publish(date, date_tag, slot)
  mp3_path = episode_mp3_path(date_tag, slot)
  abort "mp3 が見つかりません: #{mp3_path}（先に生成が必要）" unless File.exist?(mp3_path)

  used_path = episode_used_path(date_tag, slot)
  used_path = nil unless used_path && File.exist?(used_path)

  Publisher.new(date: date.to_date).run(mp3_path, used_path)
end

# 中間生成物(work/)を捨てる。last_fetch.txt（前回収集時刻の記録）は残す。
# 消すと収集 window が上限にリセットされ、次回に過去分を拾い直して重複するため。
def clean_work_dir
  targets = Dir.glob(File.join(WORK_DIR, "*")).reject { |p| File.basename(p) == "last_fetch.txt" }
  FileUtils.rm_rf(targets)
  warn "作業ディレクトリを初期化: #{WORK_DIR}"
end

# ARGV を解析する。値を取るオプション(--bgm/--date/--slot)は次の要素を消費する。
def parse_args(argv)
  opts = {}
  i = 0
  while i < argv.length
    case argv[i]
    when "--clean"         then opts[:clean] = true
    when "--generate-only" then opts[:generate_only] = true
    when "--publish-only"  then opts[:publish_only] = true
    when "--bgm"           then opts[:bgm] = argv[i += 1]
    when "--date"          then opts[:date] = Time.parse(argv[i += 1])
    when "--slot"          then opts[:slot] = argv[i += 1]
    else abort "不明な引数: #{argv[i]}"
    end
    i += 1
  end
  opts
end

main if __FILE__ == $PROGRAM_NAME
