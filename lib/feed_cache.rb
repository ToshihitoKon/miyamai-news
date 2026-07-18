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
  # フィードが取得できなかったことを表す。呼び出し側で実行の中断に使う。
  class FetchError < StandardError; end

  # @param path [String] キャッシュファイルのパス
  # @param retention_days [Integer] last_fetched_at がこれより古い entry はパージする保持日数
  # @param max_retries [Integer] フィード取得のリトライ回数
  # @param retry_base_sec [Float] 指数バックオフの初期待機秒数
  def initialize(path:, retention_days:, max_retries: 3, retry_base_sec: 2.0)
    @path = path
    @retention_days = retention_days
    @fetcher = Internal::HttpFetcher.new(max_retries: max_retries, retry_base_sec: retry_base_sec)
    # キャッシュファイルがまだ無い初回起動か。初回は全 entry の seen_at を「今」にすると
    # 掲載が古い記事まで新着扱いになってしまうので、掲載日時(date)を seen_at の初期値に
    # 使う（bootstrap）。生成時点で 1 度だけ判定する（並列 fetch でぶれないため）。
    @bootstrap = !File.exist?(path)
    # 単一キャッシュファイルを複数スレッドから更新する際の競合を防ぐ。
    # 取得（フェッチ）自体はロック外で並列に走り、キャッシュ反映だけ直列化する。
    @cache_mutex = Mutex.new
  end

  # 1 ソース分のフィード（単一 or 複数 URL）を取得・パースし、seen_at を更新したうえで
  # seen_at > since の entry を返す（since は前回収集済みの起点なので排他的下限）。返す各
  # entry は { link:, title:, date:, seen_at:, extra: }。
  #
  # 複数スレッドから同時に呼んでよい（ScriptGenerator がソースごとに並列で呼ぶ）。
  # 取得・パースはロック外で並列に走り、キャッシュの読み書きだけ Mutex で直列化する。
  #
  # 副作用としてキャッシュファイルを更新する（新規 entry の記録と、保持期間切れのパージ）。
  # 取得に失敗した場合は FetchError を送出する（不完全なまま後段へ進ませないため）。
  #
  # @param urls [String, Array<String>] 1 ソース分のフィード URL（複数可）
  # @param now [Time] seen_at として記録する現在時刻
  # @param since [Time] 前回収集済みの起点。これより後(排他的)に初登場した entry だけを返す
  # @param extra_extractor [#call, nil] フィード本文から link => 追加メタデータ の対応を
  #   作る呼び出し可能オブジェクト。ソース種別固有の情報（はてブのブックマーク数等）を
  #   FeedCache に持ち込まずに載せるための注入口。渡さなければ extra は常に nil。
  # @return [Array<Hash>]
  def fetch(urls, now:, since:, extra_extractor: nil)
    # 取得・パースはロック外。ソース間の取得を並列で走らせるため。
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

  # フィード本文をパースし、{ link:, title:, date:, extra: } の配列にする。
  # extra_extractor が渡されていれば、その結果を link で引いて each entry に合成する。
  def parse(body, extra_extractor)
    extra_by_link = extra_extractor ? extra_extractor.call(body) : {}
    Internal::FeedParser.parse(body).map { |entry| entry.merge(extra: extra_by_link[entry[:link]]) }
  rescue StandardError => e
    # HTTP は成功しているのに中身が壊れているケース。リトライしても直らないので即中断へ回す
    raise FetchError, "feed parse failed: #{e.message}"
  end

  # 今回フィードに登場した entry を seen_at 付きでキャッシュに反映する。
  # 既にある link は seen_at を据え置き（初登場時刻を保つ）、title/date/last_fetched_at/extra
  # だけ最新に更新する。
  #
  # 新規 link の seen_at は原則「今(now)」。ただし初回起動(bootstrap)時だけは、掲載が
  # 古い記事まで新着として大量に流入するのを防ぐため、掲載日時(date)を初期値に使う
  # （date が無ければ now）。2 回目以降の新規登場は now なので、昔書かれて今登場した
  # 記事も拾える。
  #
  # last_fetched_at は「直近でこのフィードに実際に見えていた時刻」。パージ判定に使う
  # （purge_expired 参照）。今回登場した entry は全て今(now)を持つ。
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

  # 今回の extra_extractor が値を出せなかった場合に、既存キャッシュから引き継ぐ。
  # meta_extra を経由することで、旧形式（トップレベル "bookmarks"）のまま更新されていない
  # entry も、新しい entry で上書きされる際に取りこぼされない。
  def existing_extra(existing)
    existing && meta_extra(existing)
  end

  def initial_seen_at(entry, now)
    return now.iso8601 unless @bootstrap && entry[:date]

    entry[:date]
  end

  # last_fetched_at（直近でこのフィードに実際に見えていた時刻）が保持期間より古い、
  # つまりフィードから既に消えて久しい entry をキャッシュから削除する。
  # seen_at で区切らないのは、フィードに載り続けている限り再登場＝二重紹介させないため
  # （クラス冒頭のコメント参照）。
  def purge_expired(cache, now)
    cutoff = now - (@retention_days * 86_400)
    cache.reject! do |_link, meta|
      # last_fetched_at を持たない旧形式の entry は、フィードに再登場すれば record_seen
      # で付与されるが、既にフィードから消えている場合は付与されないままここに来る。
      # 実在確認ができないので seen_at を代用する（bootstrap 時の initial_seen_at と
      # 同じ考え方）。seen_at は更新されない固定値なので、cutoff が進むにつれて
      # いずれ有限時間内に超過し、この entry も通常どおりパージされる。
      last_fetched_at = Time.iso8601(meta["last_fetched_at"] || meta["seen_at"])
      last_fetched_at < cutoff
    rescue ArgumentError
      # 時刻が壊れている entry は保持し続ける意味がないので落とす
      true
    end
  end

  # 今回このソースで登場した entry のうち、seen_at > since のものを返す。
  # キャッシュ全体ではなく今回の entries に絞るのは、fetch がソース単位で呼ばれるため。
  # 他ソースの entry を混ぜないよう、今回取得した link のものだけを対象にする。
  # seen_at は初登場時刻なので、キャッシュに既にある entry はその値を採る。
  # since は「前回収集済みの起点」なので排他的下限にする（>=ではなく>）。前回の収集で
  # since ちょうどに初登場した記事は収集済みなので、次回は seen_at == since を除外しないと
  # confirmed_at と seen_at が同一実行由来で一致したとき（毎回起こる）に二重紹介される。
  def select_since_for(cache, entries, since)
    # 複数 URL を持つソース（はてブ hotentry/entrylist）は同じ link が両方に載るので、
    # link で重複除去してから返す。
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

  # extra 導入前の旧キャッシュ（トップレベルの "bookmarks"）を読めるようにするフォールバック。
  # 新形式は "extra" キーにまとまっているのでそのまま返す。JSON 経由の値は常に文字列キーの
  # Hash になる（record_seen で書き込む entry[:extra] はシンボルキーだが、save_cache/
  # load_cache の JSON 往復で文字列キーに変わる）ので、呼び出し側はどちらでも文字列キーで
  # 引ける前提で扱ってよい。
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
