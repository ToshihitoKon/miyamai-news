# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require_relative "internal/http_fetcher"
require_relative "internal/feed_parser"

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
# パージは seen_at ではなく last_fetched_at（直近でそのフィードに実際に見えていたか）を
# 基準にする。OpenAI Blog のように過去記事をフィードに載せ続けるソースがあり、seen_at
# だけで区切ると「フィードにまだ載っているのに古いから」という理由でキャッシュから消えて
# しまい、次の fetch で未知の entry として再登場＝二重紹介につながる。フィードから実際に
# 消えて久しい（last_fetched_at が retention_days より古い）entry だけを間引く。
#
# キャッシュファイルの形（JSON）:
#   { "<link>": { "seen_at":, "last_fetched_at":, "title":, "date":, "extra": {} }, ... }
# link を entry の同一性キーにする。はてブの hotentry/entrylist のように同じ記事が複数
# フィードに載っても link が同じなら 1 entry として扱える。
# extra はソース種別ごとの追加メタデータ（はてブのブックマーク数など）。FeedCache は
# 中身を解釈せず透過的に保持するだけで、意味づけは呼び出し側の関心事。
class FeedCache
  class FetchError < StandardError; end

  # @param path [String] キャッシュファイルのパス
  # @param retention_days [Integer] last_fetched_at がこれより古い entry はパージする保持日数
  # @param max_retries [Integer] フィード取得のリトライ回数
  # @param retry_base_sec [Float] 指数バックオフの初期待機秒数
  def initialize(path:, retention_days:, max_retries: 3, retry_base_sec: 2.0)
    @path = path
    @retention_days = retention_days
    @fetcher = Internal::HttpFetcher.new(max_retries: max_retries, retry_base_sec: retry_base_sec)
    # キャッシュファイルがまだ無い初回起動か（bootstrap時のseen_at初期値に使う。
    # 詳細はCLAUDE.md参照）。生成時点で1度だけ判定する（並列fetchでもぶれないため）。
    @bootstrap = !File.exist?(path)
    # キャッシュファイルへの書き込みを直列化する（詳細はfetch参照）。
    @cache_mutex = Mutex.new
  end

  # 1 ソース分のフィード（単一 or 複数 URL）を取得・パースし、seen_at を更新したうえで
  # seen_at > since の entry を返す（排他的下限。理由はCLAUDE.md参照）。副作用として
  # キャッシュファイルを更新し、取得失敗時は FetchError を送出する。
  # 複数スレッドから同時に呼んでよい（取得は並列、キャッシュ反映のみ直列化）。
  #
  # @param urls [String, Array<String>] 1 ソース分のフィード URL（複数可）
  # @param now [Time] seen_at として記録する現在時刻
  # @param since [Time] 前回収集済みの起点（排他的下限）
  # @param extra_extractor [#call, nil] ソース種別固有メタデータの注入口
  # @return [Array<Hash>]
  def fetch(urls, now:, since:, extra_extractor: nil)
    entries = Array(urls).flat_map { |url| fetch_and_parse(url, extra_extractor) }

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

  def fetch_and_parse(url, extra_extractor)
    parse(fetch_body(url), extra_extractor)
  end

  def fetch_body(url)
    @fetcher.get(url)
  rescue StandardError => e
    raise FetchError, e.message
  end

  def parse(body, extra_extractor)
    extra_by_link = extra_extractor ? extra_extractor.call(body) : {}
    Internal::FeedParser.parse(body).map { |entry| entry.merge(extra: extra_by_link[entry[:link]]) }
  rescue StandardError => e
    # HTTP は成功しているのに中身が壊れているケース。リトライしても直らないので即中断へ回す
    raise FetchError, "feed parse failed: #{e.message}"
  end

  # 今回登場した entry を seen_at 付きでキャッシュへ反映する。既存 link は seen_at を
  # 据え置き、他フィールドのみ最新化する（新規 entry の seen_at は initial_seen_at 参照）。
  def record_seen(cache, entries, now)
    entries.each do |entry|
      existing = cache[entry[:link]]
      cache[entry[:link]] = {
        "seen_at" => existing ? existing["seen_at"] : initial_seen_at(entry, now),
        "last_fetched_at" => now.iso8601,
        "title" => entry[:title],
        "date" => entry[:date],
        "extra" => entry[:extra] || existing_extra(existing),
      }
    end
  end

  # extra_extractor が値を出せなかった場合、既存キャッシュから引き継ぐ。
  def existing_extra(existing)
    existing && meta_extra(existing)
  end

  def initial_seen_at(entry, now)
    return now.iso8601 unless @bootstrap && entry[:date]

    entry[:date]
  end

  # last_fetched_at が保持期間より古い entry を削除する（理由はクラス冒頭のコメント参照）。
  def purge_expired(cache, now)
    cutoff = now - (@retention_days * 86_400)
    cache.reject! do |_link, meta|
      # last_fetched_at が無い旧形式 entry は seen_at で代用する（bootstrap と同じ考え方）。
      # seen_at は更新されないので、cutoff が進めばいずれ通常どおりパージされる。
      last_fetched_at = Time.iso8601(meta["last_fetched_at"] || meta["seen_at"])
      last_fetched_at < cutoff
    rescue ArgumentError
      # 時刻が壊れている entry は保持し続ける意味がないので落とす
      true
    end
  end

  # 今回このソースで登場した entry のうち seen_at > since のものを返す（今回の
  # entries のみが対象）。
  # since は排他的下限（>=ではなく>）: confirmed_at と同一実行由来の seen_at が
  # 一致し得るため、含めると同じ記事を毎回新着として二重紹介してしまう。
  def select_since_for(cache, entries, since)
    # 複数 URL ソースは同じ link が重複しうるので先に除去する。
    entries.uniq { |e| e[:link] }.filter_map do |entry|
      meta = cache[entry[:link]] or next
      seen_at = Time.iso8601(meta["seen_at"])
      next if seen_at <= since

      { link: entry[:link], title: meta["title"], date: meta["date"],
        seen_at: meta["seen_at"], extra: meta_extra(meta) }
    rescue ArgumentError
      nil
    end
  end

  # 旧形式（トップレベル "bookmarks"）を読めるようにするフォールバック。JSON 往復後は
  # 常に文字列キーになる点は hatena_bookmarks.rb と共通（CLAUDE.md 参照）。
  def meta_extra(meta)
    meta["extra"] || (meta["bookmarks"] ? { "bookmarks" => meta["bookmarks"] } : nil)
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
end
