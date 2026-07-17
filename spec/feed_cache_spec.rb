# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "time"
require "feed_cache"

RSpec.describe FeedCache do
  let(:work_dir) { Dir.mktmpdir }
  let(:cache) { FeedCache.new(path: File.join(work_dir, "feed_cache.json"), retention_days: 7) }

  after { FileUtils.remove_entry(work_dir) }

  describe "#select_since_for" do
    # since は「前回収集済みの起点」。収集起点(confirmed_at)は前回の実行の @now 由来で、
    # その実行で初登場した記事の seen_at も同じ @now なので、両者は毎回ちょうど一致する。
    # 境界を含める(>=)と、前回収集済みの記事が翌回に必ず再登場して二重紹介になる。
    it "excludes an entry whose seen_at is exactly since (already collected last time)" do
      since = Time.utc(2026, 7, 17, 18, 27, 16)
      link = "https://example.com/v2.1.212"
      cache_data = { link => { "seen_at" => since.iso8601, "title" => "Release", "date" => "2026-07-17" } }
      entries = [{ link: link }]

      result = cache.send(:select_since_for, cache_data, entries, since)

      expect(result).to be_empty
    end

    it "includes an entry whose seen_at is strictly after since" do
      since = Time.utc(2026, 7, 17, 18, 27, 16)
      link = "https://example.com/new"
      seen_at = since + 1
      cache_data = { link => { "seen_at" => seen_at.iso8601, "title" => "Newer", "date" => "2026-07-18" } }
      entries = [{ link: link }]

      result = cache.send(:select_since_for, cache_data, entries, since)

      expect(result.map { |e| e[:link] }).to eq([link])
    end

    it "excludes an entry whose seen_at is before since" do
      since = Time.utc(2026, 7, 17, 18, 27, 16)
      link = "https://example.com/old"
      cache_data = { link => { "seen_at" => (since - 3600).iso8601, "title" => "Old", "date" => "2026-07-17" } }
      entries = [{ link: link }]

      result = cache.send(:select_since_for, cache_data, entries, since)

      expect(result).to be_empty
    end
  end
end
