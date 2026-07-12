# frozen_string_literal: true

require "rss"
require "rexml/document"
require "json"
require "net/http"
require "uri"
require "time"
require "fileutils"

# RSS/Atom フィードの取得・パースと、entry の「初登場時刻(seen_at)」の記録を担う小さな
# キャッシュ層。
#
# 掲載日時ではなく seen_at（このキャッシュが entry を初めて見た時刻）で新着を判断する。
# はてブや Qiita のようなキュレーション系フィードは、昔書かれた記事が今になって話題化し
# フィードに載ることがある。掲載日時で足切りするとそれを取りこぼすため、「いつフィードに
# 登場したか」を基準にする。RSS リーダーの未読管理に近い考え方。
#
# used（実際に台本で紹介したか）のような業務状態は持たない。それは呼び出し側の関心事。
#
# キャッシュファイルの形（JSON）:
#   { "<link>": { "seen_at":, "title":, "date":, "bookmarks": }, ... }
# link を entry の同一性キーにする。はてブの hotentry/entrylist のように同じ記事が複数
# フィードに載っても link が同じなら 1 entry として扱える。
# bookmarks ははてブのブックマーク数（はてブ以外のフィードでは nil）。
class FeedCache
  # フィードが取得できなかったことを表す。呼び出し側で実行の中断に使う。
  class FetchError < StandardError; end

  # @param path [String] キャッシュファイルのパス
  # @param retention_days [Integer] seen_at がこれより古い entry はパージする保持日数
  # @param max_retries [Integer] フィード取得のリトライ回数
  # @param retry_base_sec [Float] 指数バックオフの初期待機秒数
  def initialize(path:, retention_days:, max_retries: 3, retry_base_sec: 2.0)
    @path = path
    @retention_days = retention_days
    @max_retries = max_retries
    @retry_base_sec = retry_base_sec
    # キャッシュファイルがまだ無い初回起動か。初回は全 entry の seen_at を「今」にすると
    # 掲載が古い記事まで新着扱いになってしまうので、掲載日時(date)を seen_at の初期値に
    # 使う（bootstrap）。生成時点で 1 度だけ判定する（並列 fetch でぶれないため）。
    @bootstrap = !File.exist?(path)
    # 単一キャッシュファイルを複数スレッドから更新する際の競合を防ぐ。
    # 取得（http_get）自体はロック外で並列に走り、キャッシュ反映だけ直列化する。
    @cache_mutex = Mutex.new
  end

  # 1 ソース分のフィード（単一 or 複数 URL）を取得・パースし、seen_at を更新したうえで
  # seen_at >= since の entry を返す。返す各 entry は
  # { link:, title:, date:, seen_at:, bookmarks: }。
  #
  # 複数スレッドから同時に呼んでよい（ScriptGenerator がソースごとに並列で呼ぶ）。
  # 取得・パースはロック外で並列に走り、キャッシュの読み書きだけ Mutex で直列化する。
  #
  # 副作用としてキャッシュファイルを更新する（新規 entry の記録と、保持期間切れのパージ）。
  # 取得に失敗した場合は FetchError を送出する（不完全なまま後段へ進ませないため）。
  #
  # @param urls [String, Array<String>] 1 ソース分のフィード URL（複数可）
  # @param now [Time] seen_at として記録する現在時刻
  # @param since [Time] これ以降に初登場した entry だけを返す下限
  # @return [Array<Hash>]
  def fetch(urls, now:, since:)
    # http_get はロック外。ソース間の取得を並列で走らせるため。
    entries = Array(urls).flat_map { |url| parse_entries(http_get(url)) }

    @cache_mutex.synchronize do
      cache = load_cache
      record_seen(cache, entries, now)
      purge_expired(cache, now)
      save_cache(cache)
      select_since_for(cache, entries, since)
    end
  end

  # entry の同一性キー（link）。呼び出し側が used 判定などで同じキーを使えるよう公開する。
  def self.key(entry) = entry[:link]

  private

  # 今回フィードに登場した entry を seen_at 付きでキャッシュに反映する。
  # 既にある link は seen_at を据え置き（初登場時刻を保つ）、title/date だけ最新に更新する。
  #
  # 新規 link の seen_at は原則「今(now)」。ただし初回起動(bootstrap)時だけは、掲載が
  # 古い記事まで新着として大量に流入するのを防ぐため、掲載日時(date)を初期値に使う
  # （date が無ければ now）。2 回目以降の新規登場は now なので、昔書かれて今登場した
  # 記事も拾える。
  def record_seen(cache, entries, now)
    entries.each do |entry|
      existing = cache[entry[:link]]
      cache[entry[:link]] = {
        "seen_at" => existing ? existing["seen_at"] : initial_seen_at(entry, now),
        "title" => entry[:title],
        "date" => entry[:date],
        "bookmarks" => entry[:bookmarks],
      }
    end
  end

  def initial_seen_at(entry, now)
    return now.iso8601 unless @bootstrap && entry[:date]

    entry[:date]
  end

  # seen_at が保持期間より古い entry をキャッシュから削除する。
  def purge_expired(cache, now)
    cutoff = now - (@retention_days * 86_400)
    cache.reject! do |_link, meta|
      seen_at = Time.iso8601(meta["seen_at"])
      seen_at < cutoff
    rescue ArgumentError
      # seen_at が壊れている entry は保持し続ける意味がないので落とす
      true
    end
  end

  # 今回このソースで登場した entry のうち、seen_at >= since のものを返す。
  # キャッシュ全体ではなく今回の entries に絞るのは、fetch がソース単位で呼ばれるため。
  # 他ソースの entry を混ぜないよう、今回取得した link のものだけを対象にする。
  # seen_at は初登場時刻なので、キャッシュに既にある entry はその値を採る。
  def select_since_for(cache, entries, since)
    # 複数 URL を持つソース（はてブ hotentry/entrylist）は同じ link が両方に載るので、
    # link で重複除去してから返す。
    entries.uniq { |e| e[:link] }.filter_map do |entry|
      meta = cache[entry[:link]] or next
      seen_at = Time.iso8601(meta["seen_at"])
      next if seen_at < since

      { link: entry[:link], title: meta["title"], date: meta["date"],
        seen_at: meta["seen_at"], bookmarks: meta["bookmarks"] }
    rescue ArgumentError
      nil
    end
  end

  def load_cache
    return {} unless File.exist?(@path)

    JSON.parse(File.read(@path))
  rescue JSON::ParserError
    {}
  end

  def save_cache(cache)
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, JSON.pretty_generate(cache))
  end

  # --- フィード取得・パース ---

  # フィードを取得して本文を返す。失敗時は指数バックオフで max_retries 回まで再試行し、
  # それでも取れなければ FetchError を投げる。hnrss などは一時的に 502 を返すことがある。
  def http_get(url)
    attempt = 0
    begin
      http_get_once(url)
    rescue StandardError => e
      attempt += 1
      raise FetchError, "#{url} の取得に失敗: #{e.message}" if attempt > @max_retries

      wait = @retry_base_sec * (2**(attempt - 1))
      warn "  ! #{url} の取得に失敗（#{attempt}/#{@max_retries} 回目）: #{e.message} / #{wait}秒後に再試行"
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

  # フィード本文をパースし、{ link:, title:, date:, bookmarks: } の配列にする。
  # date は掲載日時。取れないソースは nil。掲載日時では足切りしない（seen_at で扱う）。
  # bookmarks ははてブフィードのブックマーク数。それ以外のフィードでは nil。
  def parse_entries(body)
    feed = RSS::Parser.parse(body, false)
    return [] unless feed

    bookmarks = hatena_bookmark_counts(body)
    feed.items.filter_map do |item|
      title = item.respond_to?(:title) && item.title or next
      title = title.respond_to?(:content) ? title.content : title.to_s
      link  = item.link.respond_to?(:href) ? item.link.href : item.link.to_s
      date  = item_date(item)
      link  = normalize_link(link)

      { title: title.strip, link: link, date: date&.iso8601, bookmarks: bookmarks[link] }
    end
  rescue StandardError => e
    # HTTP は成功しているのに中身が壊れているケース。リトライしても直らないので即中断へ回す
    raise FetchError, "フィードのパースに失敗: #{e.message}"
  end

  # はてブ RSS(RDF) から link → ブックマーク数 の対応を作る。
  # rss gem は hatena 名前空間の要素を公開しないため、REXML で直接引く。はてブ以外の
  # フィードには hatena:bookmarkcount が無いので空ハッシュになる（bookmarks は nil になる）。
  def hatena_bookmark_counts(body)
    doc = REXML::Document.new(body)
    pairs = doc.get_elements("//item").to_h do |item|
      [normalize_link(item.elements["link"]&.text.to_s),
       item.elements["hatena:bookmarkcount"]&.text&.to_i]
    end
    pairs.reject { |link, count| link.empty? || count.nil? }
  rescue REXML::ParseException
    {}
  end

  # 同じ記事が末尾スラッシュの有無だけ違う URL でフィードに載ることがあり、素通しすると
  # FeedCache が別 entry と誤認して二重に新着扱いしてしまう。同一性キーとして使う前に
  # ここで正規化して吸収する。"https://example.com" と "https://example.com/" も同一視
  # する（パスが空＝ルートを指す同じ URL のため）。"https://" 自体は消さないよう、
  # スキーム直後の "//" だけは対象から除く。
  def normalize_link(link)
    link = link.strip
    link.sub(%r{(?<!:)/+\z}, "")
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
end
