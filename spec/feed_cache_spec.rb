# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "time"
require "json"
require "feed_cache"

RSpec.describe FeedCache do
  let(:dir) { Dir.mktmpdir }
  let(:url) { "https://example.com/feed.rss" }
  # 取得・パースを直列化する Mutex は廃止したので、fetch は @fetcher の get 戻り値を素通し
  # でパースする。テストは @fetcher をスタブして任意のフィード本文を返させる。
  let(:fetcher) { instance_double(Internal::HttpFetcher) }

  after { FileUtils.remove_entry(dir) }

  # link/title の組から最小の RSS 2.0 本文を作る。date は付けない（seen_at 判定は now 基準）。
  def rss_for(items)
    body = items.map { |link, title| "<item><title>#{title}</title><link>#{link}</link></item>" }.join
    "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel>#{body}</channel></rss>"
  end

  def build_cache(skip_window_sec: 0, retention_days: 7, legacy_path: nil)
    cache = FeedCache.new(dir: dir, retention_days: retention_days,
      skip_window_sec: skip_window_sec, legacy_path: legacy_path)
    cache.instance_variable_set(:@fetcher, fetcher)
    cache
  end

  # そのフィードのキャッシュファイルの中身（JSON）を読む。
  def read_cache_file
    path = Dir.glob(File.join(dir, "*.json")).first
    path && JSON.parse(File.read(path))
  end

  describe "#select_since_for" do
    let(:cache) { build_cache }

    # since は「前回収集済みの起点」。収集起点(confirmed_at)は前回の実行の @now 由来で、
    # その実行で初登場した記事の seen_at も同じ @now なので、両者は毎回ちょうど一致する。
    # 境界を含める(>=)と、前回収集済みの記事が翌回に必ず再登場して二重紹介になる。
    it "excludes an entry whose seen_at is exactly since (already collected last time)" do
      since = Time.utc(2026, 7, 17, 18, 27, 16)
      link = "https://example.com/v2.1.212"
      entries = { link => { "seen_at" => since.iso8601, "title" => "Release", "date" => "2026-07-17" } }

      result = cache.send(:select_since_for, entries, [{ link: link }], since)

      expect(result).to be_empty
    end

    it "includes an entry whose seen_at is strictly after since" do
      since = Time.utc(2026, 7, 17, 18, 27, 16)
      link = "https://example.com/new"
      entries = { link => { "seen_at" => (since + 1).iso8601, "title" => "Newer", "date" => "2026-07-18" } }

      result = cache.send(:select_since_for, entries, [{ link: link }], since)

      expect(result.map { |e| e[:link] }).to eq([link])
    end

    it "excludes an entry whose seen_at is before since" do
      since = Time.utc(2026, 7, 17, 18, 27, 16)
      link = "https://example.com/old"
      entries = { link => { "seen_at" => (since - 3600).iso8601, "title" => "Old", "date" => "2026-07-17" } }

      result = cache.send(:select_since_for, entries, [{ link: link }], since)

      expect(result).to be_empty
    end
  end

  describe "#fetch" do
    let(:since) { Time.utc(2026, 7, 1) }
    let(:now) { Time.utc(2026, 7, 10, 12, 0, 0) }

    it "records fetched entries into a per-url cache file keyed by link" do
      cache = build_cache
      allow(fetcher).to receive(:get).and_return(rss_for([["https://example.com/a", "Alpha"]]))

      result = cache.fetch(url, now: now, since: since)

      expect(result.map { |e| e[:link] }).to eq(["https://example.com/a"])
      file = read_cache_file
      expect(file["url"]).to eq(url)
      expect(file["fetched_at"]).to eq(now.iso8601)
      expect(file["entries"].keys).to eq(["https://example.com/a"])
      expect(file["entries"]["https://example.com/a"]["seen_at"]).to eq(now.iso8601)
    end

    context "short-term skip" do
      # 直近 fetch のキャッシュを用意してから、skip_window 内/外で挙動を分ける。
      def seed_cache!(fetched_at)
        cache = build_cache
        allow(fetcher).to receive(:get).and_return(rss_for([["https://example.com/a", "Alpha"]]))
        cache.fetch(url, now: fetched_at, since: since)
      end

      it "skips HTTP and reproduces the previous result within the window" do
        seed_cache!(now)
        cache = build_cache(skip_window_sec: 300)
        expect(fetcher).not_to receive(:get)

        result = cache.fetch(url, now: now + 60, since: since)

        expect(result.map { |e| e[:link] }).to eq(["https://example.com/a"])
      end

      it "leaves the cache file untouched when skipping" do
        seed_cache!(now)
        before = read_cache_file
        cache = build_cache(skip_window_sec: 300)
        allow(fetcher).to receive(:get)

        cache.fetch(url, now: now + 60, since: since)

        expect(read_cache_file).to eq(before)
      end

      it "fetches again once the window has elapsed" do
        seed_cache!(now)
        cache = build_cache(skip_window_sec: 300)
        # skip_window ちょうど(300秒後)は排他的なのでスキップされず、再取得が走る。
        expect(fetcher).to receive(:get).and_return(rss_for([["https://example.com/a", "Alpha"]]))

        cache.fetch(url, now: now + 300, since: since)
      end

      it "always fetches when skip is disabled (skip_window_sec: 0)" do
        seed_cache!(now)
        cache = build_cache(skip_window_sec: 0)
        expect(fetcher).to receive(:get).and_return(rss_for([["https://example.com/a", "Alpha"]]))

        cache.fetch(url, now: now + 1, since: since)
      end

      it "returns the same links whether it fetched or skipped" do
        # seen_at > since を満たす 2 記事。通常 fetch と skip fetch で返り link 集合が一致する。
        seed_cache!(now)
        skipped = build_cache(skip_window_sec: 300)
        allow(fetcher).to receive(:get)
        skip_result = skipped.fetch(url, now: now + 60, since: since)

        refetched = build_cache(skip_window_sec: 0)
        allow(fetcher).to receive(:get).and_return(rss_for([["https://example.com/a", "Alpha"]]))
        fetch_result = refetched.fetch(url, now: now + 60, since: since)

        expect(skip_result.map { |e| e[:link] }).to eq(fetch_result.map { |e| e[:link] })
      end
    end

    context "legacy seen_at inheritance" do
      let(:legacy_path) { File.join(dir, "legacy.json") }
      let(:legacy_seen_at) { Time.utc(2026, 6, 15).iso8601 }

      before do
        # 旧・単一ファイル形式（link キーのフラット構造）に既知の記事を置く。
        File.write(legacy_path, JSON.generate(
          "https://example.com/a" => { "seen_at" => legacy_seen_at, "title" => "Alpha" }
        ))
      end

      it "inherits seen_at from the legacy ledger on a feed's first fetch" do
        cache = build_cache(legacy_path: legacy_path)
        allow(fetcher).to receive(:get).and_return(rss_for([["https://example.com/a", "Alpha"]]))

        cache.fetch(url, now: now, since: since)

        expect(read_cache_file["entries"]["https://example.com/a"]["seen_at"]).to eq(legacy_seen_at)
      end

      it "uses now for a link that is not in the legacy ledger" do
        cache = build_cache(legacy_path: legacy_path)
        allow(fetcher).to receive(:get).and_return(rss_for([["https://example.com/fresh", "Fresh"]]))

        cache.fetch(url, now: now, since: since)

        expect(read_cache_file["entries"]["https://example.com/fresh"]["seen_at"]).to eq(now.iso8601)
      end
    end
  end
end
