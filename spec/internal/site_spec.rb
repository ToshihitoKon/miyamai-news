# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "internal/site"

RSpec.describe Internal::Site do
  let(:s3) { Aws::S3::Client.new(stub_responses: true, region: "auto") }
  let(:storage) { Internal::R2Storage.new(bucket: "test-bucket", client: s3) }
  let(:deployed) { [] }
  let(:site) do
    described_class.new(
      public_base: "https://news.example.com",
      retention_episodes: 5,
      storage: storage,
      deployer: ->(dir) { deployed << dir; true }
    )
  end

  describe "#url_for" do
    it "serves generated pages from the site root" do
      expect(site.url_for("feed.xml")).to eq("https://news.example.com/feed.xml")
      expect(site.url_for("manifest.json")).to eq("https://news.example.com/manifest.json")
    end

    # static assets 側が /index.html を "/" へ 307 リダイレクトするので、
    # 正規形を返さないと feed の link や og:url が毎回リダイレクトを挟む。
    it "returns the canonical root for index.html instead of the redirecting form" do
      expect(site.url_for("index.html")).to eq("https://news.example.com/")
    end

    # 再生ページの JS は mp3 URL の拡張子だけを差し替えて兄弟ファイルを引くため、
    # mp3 とその派生物は同じ階層に並んでいる必要がある。
    it "keeps episode files and their siblings on the same path level" do
      mp3 = site.url_for("ep.mp3")

      expect(mp3).to eq("https://news.example.com/episodes/ep.mp3")
      expect(mp3.sub(/\.mp3\z/, ".used.html")).to eq(site.url_for("ep.used.html"))
    end
  end

  describe "#tag_uri" do
    it "builds an RFC 4151 tag URI from the site host" do
      expect(site.tag_uri("2026-07-14", "ep")).to eq("tag:news.example.com,2026-07-14:ep")
    end

    # 配信 URL から独立していることが要件。ホストが同じなら公開先のパスや
    # スキーム構成が変わっても ID は動かない。
    it "does not embed the delivery path" do
      uri = site.tag_uri("2026-07-14", "ep")

      expect(uri).not_to include("https://")
      expect(uri).not_to include("/episodes/")
    end
  end

  # 版権素材を Git にもデプロイ成果物にも含めないため、画像は R2 に置いて
  # Worker 経由で配信する。
  describe "assets" do
    it "serves assets from their own prefix, outside the episode prefix" do
      url = site.asset_url("cover.webp")

      expect(url).to eq("https://news.example.com/assets/cover.webp")
      expect(url).not_to include("/episodes/")
    end

    it "uploads assets with a long cache lifetime" do
      captured = nil
      s3.stub_responses(:put_object, ->(ctx) { captured = ctx.params; {} })

      Dir.mktmpdir do |dir|
        path = File.join(dir, "cover.webp")
        File.write(path, "binary")
        site.upload_asset("cover.webp", path, content_type: "image/webp")
      end

      expect(captured[:key]).to eq("assets/cover.webp")
      expect(captured[:content_type]).to eq("image/webp")
      expect(captured[:cache_control]).to eq(described_class::ASSET_CACHE_CONTROL)
    end

    # 退避されるとサイトの画像が消えるので、エピソードのプレフィックスとは
    # 別に保つ。
    it "keeps assets out of the retention lifecycle" do
      expect(site.asset_url("cover.webp")).not_to include("/episodes/")
      expect(site.asset_url("cover.webp")).not_to include("/archived/")
    end
  end

  describe "#write_episode_file" do
    it "writes in-memory content beneath the episode-asset prefix" do
      captured = nil
      s3.stub_responses(:put_object, ->(ctx) { captured = ctx.params; {} })

      site.write_episode_file("ep.used.txt", "body", content_type: "text/plain")

      expect(captured[:key]).to eq("episodes/ep.used.txt")
      expect(captured[:content_type]).to eq("text/plain")
      expect(captured[:body]).to eq("body")
    end
  end

  describe "#upload_episode_file" do
    it "uploads a local file beneath the episode-asset prefix" do
      captured = nil
      s3.stub_responses(:put_object, ->(ctx) { captured = ctx.params; {} })

      Dir.mktmpdir do |dir|
        path = File.join(dir, "ep.mp3")
        File.write(path, "fake mp3")

        site.upload_episode_file("ep.mp3", path, content_type: "audio/mpeg")
      end

      expect(captured[:key]).to eq("episodes/ep.mp3")
      expect(captured[:content_type]).to eq("audio/mpeg")
    end
  end

  describe "#retire_episode_file" do
    # 退避先が資材プレフィックス配下だと公開経路に残り、保持件数を超えた回が
    # 読めるままになる。
    it "moves the object out of the episode-asset prefix" do
      captured = nil
      s3.stub_responses(:head_object, {})
      s3.stub_responses(:copy_object, ->(ctx) { captured = ctx.params; { copy_object_result: {} } })
      s3.stub_responses(:delete_object, {})

      site.retire_episode_file("ep.mp3")

      expect(captured[:copy_source]).to eq("test-bucket/episodes/ep.mp3")
      expect(captured[:key]).to eq("archived/ep.mp3")
      expect(captured[:key]).not_to start_with("episodes/")
    end
  end

  describe "#read_ledger / #write_ledger" do
    it "reads the ledger from outside the public episode prefix" do
      captured = nil
      s3.stub_responses(:get_object, ->(ctx) { captured = ctx.params; { body: "a,b\n" } })

      expect(site.read_ledger).to eq("a,b\n")
      expect(captured[:key]).to eq("archives.csv")
    end

    it "raises LedgerMissing when the ledger is absent" do
      s3.stub_responses(:get_object, "NoSuchKey")

      expect { site.read_ledger }.to raise_error(described_class::LedgerMissing)
    end

    it "writes the ledger as text/csv" do
      captured = nil
      s3.stub_responses(:put_object, ->(ctx) { captured = ctx.params; {} })

      site.write_ledger("a,b\n")

      expect(captured[:key]).to eq("archives.csv")
      expect(captured[:content_type]).to eq("text/csv")
    end
  end

  describe "#deploy" do
    it "writes delivery headers into the staging directory before deploying" do
      Dir.mktmpdir do |dir|
        site.deploy(dir)

        headers = File.read(File.join(dir, "_headers"))
        expect(headers).to include("/feed.xml")
        expect(headers).to include("Content-Type: application/atom+xml; charset=utf-8")
        expect(deployed).to eq([dir])
      end
    end

    it "raises DeployFailed when the deploy reports failure" do
      failing = described_class.new(
        public_base: "https://news.example.com", retention_episodes: 5,
        storage: storage, deployer: ->(_dir) { false }
      )

      Dir.mktmpdir do |dir|
        expect { failing.deploy(dir) }.to raise_error(described_class::DeployFailed)
      end
    end
  end

  describe ".from_config" do
    it "builds from the cloudflare section" do
      built = described_class.from_config

      expect(built.retention_episodes).to eq(Config.cloudflare.retention_episodes)
      expect(built.page_url("index.html")).to start_with(Config.cloudflare.public_base)
    end
  end
end
