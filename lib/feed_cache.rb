# frozen_string_literal: true

require "json"
require "time"
require "digest"
require "fileutils"
require_relative "internal/http_fetcher"
require_relative "internal/feed_parser"

# RSS/Atom フィードの取得・パースと、entry の「初登場時刻(seen_at)」の記録を担う小さな
# キャッシュ層。
class FeedCache
  class FetchError < StandardError; end

  def initialize(dir:, retention_days:, skip_window_sec: 0, legacy_path: nil,
                 max_retries: 3, retry_base_sec: 2.0)
    @dir = dir
    @retention_days = retention_days
    @skip_window_sec = skip_window_sec
    @fetcher = Internal::HttpFetcher.new(max_retries: max_retries, retry_base_sec: retry_base_sec)
    @legacy_seen_at = load_legacy_seen_at(legacy_path)
  end

  # 1 フィード（単一 URL）を取得・パースし、seen_at を更新したうえで seen_at > since の
  # entry を返す。返す各 entry は
  # { link:, title:, date:, seen_at:, extra: }。
  def fetch(url, now:, since:, extra_extractor: nil)
    cache = load_cache(url)
    if skip?(cache, now)
      warn "skipped: #{url}"
      return select_since_for(cache["entries"], cached_entries(cache), since)
    end

    warn "fetched: #{url}"
    entries = fetch_and_parse(url, extra_extractor)
    record_seen(cache["entries"], entries, now)
    purge_expired(cache["entries"], now)
    cache["fetched_at"] = now.iso8601
    save_cache(url, cache)
    select_since_for(cache["entries"], entries, since)
  end

  private

  # 最終 fetch から skip_window_sec 以内なら true。
  def skip?(cache, now)
    return false unless @skip_window_sec.positive?

    fetched_at = cache["fetched_at"]
    return false unless fetched_at

    now - Time.iso8601(fetched_at) < @skip_window_sec
  rescue ArgumentError
    false
  end

  # スキップ時に select_since_for へ渡す擬似 entries。
  def cached_entries(cache)
    cache["entries"].select { |_link, meta| meta["last_fetched_at"] == cache["fetched_at"] }
      .keys.map { |link| { link: link } }
  end

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
    raise FetchError, "feed parse failed: #{e.message}"
  end

  # 今回フィードに登場した entry を seen_at 付きでキャッシュに反映する。既にある link は
  # title/date/last_fetched_at/extra だけ最新化する。新規 link の seen_at 初期値は
  # initial_seen_at。
  def record_seen(entries, fetched, now)
    fetched.each do |entry|
      existing = entries[entry[:link]]
      entries[entry[:link]] = {
        "seen_at" => existing ? existing["seen_at"] : initial_seen_at(entry, now),
        "last_fetched_at" => now.iso8601,
        "title" => entry[:title],
        "date" => entry[:date],
        "extra" => entry[:extra] || existing_extra(existing),
      }
    end
  end

  # 既存キャッシュから extra を引き継ぐ。
  def existing_extra(existing)
    existing && meta_extra(existing)
  end

  # 新規 link の seen_at 初期値。旧台帳にあればその値を継承し、無ければ now。
  def initial_seen_at(entry, now)
    @legacy_seen_at[entry[:link]] || now.iso8601
  end

  # last_fetched_at が保持期間より古い entry を間引く。
  def purge_expired(entries, now)
    cutoff = now - (@retention_days * 86_400)
    entries.reject! do |_link, meta|
      last_fetched_at = Time.iso8601(meta["last_fetched_at"] || meta["seen_at"])
      last_fetched_at < cutoff
    rescue ArgumentError
      true
    end
  end

  # 今回このフィードで登場した entry のうち、seen_at > since のものを返す。
  def select_since_for(entries, fetched, since)
    fetched.uniq { |e| e[:link] }.filter_map do |entry|
      meta = entries[entry[:link]] or next
      seen_at = Time.iso8601(meta["seen_at"])
      next if seen_at <= since

      { link: entry[:link], title: meta["title"], date: meta["date"],
        seen_at: meta["seen_at"], extra: meta_extra(meta) }
    rescue ArgumentError
      nil
    end
  end

  # 旧キャッシュ（トップレベルの "bookmarks"）を読むフォールバック。
  def meta_extra(meta)
    meta["extra"] || (meta["bookmarks"] ? { "bookmarks" => meta["bookmarks"] } : nil)
  end

  # URL に対応するキャッシュファイルのパス。正規化した URL の SHA1 を名前にする。
  def cache_path(url)
    File.join(@dir, "#{Digest::SHA1.hexdigest(Internal::FeedParser.normalize_link(url))}.json")
  end

  # URL 別キャッシュを読む。無い/パース不能なら空の骨組みを返す（entries が無いフィード初回）。
  def load_cache(url)
    path = cache_path(url)
    return { "url" => url, "fetched_at" => nil, "entries" => {} } unless File.exist?(path)

    data = JSON.parse(File.read(path))
    unless data.is_a?(Hash)
      abort("#{path} is valid JSON but not an object; refusing to treat #{url} as a fresh " \
            "cache (that would re-introduce every entry as new). Inspect/repair it manually " \
            "(or with AI assistance) and re-run.")
    end

    data["entries"] ||= {}
    data
  rescue JSON::ParserError
    { "url" => url, "fetched_at" => nil, "entries" => {} }
  end

  # tmp へ書いてから rename する。
  def save_cache(url, cache)
    FileUtils.mkdir_p(@dir)
    path = cache_path(url)
    tmp = "#{path}.tmp"
    File.write(tmp, JSON.pretty_generate(cache))
    File.rename(tmp, path)
  end

  # 旧・単一ファイル形式のキャッシュから link => seen_at の対応を読む。書き換えはしない。
  # 無い/壊れていれば空 Hash。
  def load_legacy_seen_at(legacy_path)
    return {} unless legacy_path && File.exist?(legacy_path)

    JSON.parse(File.read(legacy_path)).each_with_object({}) do |(link, meta), acc|
      seen_at = meta.is_a?(Hash) && meta["seen_at"]
      acc[link] = seen_at if seen_at
    end
  rescue JSON::ParserError
    {}
  end
end
