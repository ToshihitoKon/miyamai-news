# frozen_string_literal: true

require "spec_helper"
require "publish_target"

RSpec.describe PublishTarget do
  let(:s3) { Aws::S3::Client.new(stub_responses: true, region: "auto") }
  let(:storage) { Internal::R2Storage.new(bucket: "test-bucket", client: s3) }
  let(:deployed) { [] }
  let(:target) do
    described_class.new(
      public_base: "https://news.example.com",
      retention_episodes: 5,
      storage: storage,
      deployer: ->(dir) { deployed << dir; true }
    )
  end

  describe "#url_for" do
    it "serves generated pages from the site root" do
      described_class::PAGE_OBJECTS.each do |page|
        expect(target.url_for(page)).to eq("https://news.example.com/#{page}")
      end
    end

    # 再生ページの JS は mp3 URL の拡張子だけを差し替えて兄弟ファイルを引くため、
    # mp3 とその派生物は同じ階層に並んでいる必要がある。
    it "keeps episode files and their siblings on the same path level" do
      mp3 = target.url_for("ep.mp3")

      expect(mp3).to eq("https://news.example.com/audio/ep.mp3")
      expect(mp3.sub(/\.mp3\z/, ".used.html")).to eq(target.url_for("ep.used.html"))
    end
  end

  describe "#put_episode_content" do
    it "writes beneath the episode-asset prefix" do
      captured = nil
      s3.stub_responses(:put_object, ->(ctx) { captured = ctx.params; {} })

      target.put_episode_content("ep.used.txt", "body", content_type: "text/plain")

      expect(captured[:key]).to eq("audio/ep.used.txt")
      expect(captured[:content_type]).to eq("text/plain")
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

      target.retire_episode_file("ep.mp3")

      expect(captured[:copy_source]).to eq("test-bucket/audio/ep.mp3")
      expect(captured[:key]).to eq("archived/ep.mp3")
      expect(captured[:key]).not_to start_with("audio/")
    end
  end

  describe "#read_ledger / #write_ledger" do
    it "reads the ledger from outside the public episode prefix" do
      captured = nil
      s3.stub_responses(:get_object, ->(ctx) { captured = ctx.params; { body: "a,b\n" } })

      expect(target.read_ledger).to eq("a,b\n")
      expect(captured[:key]).to eq("archives.csv")
    end

    it "raises LedgerMissing when the ledger is absent" do
      s3.stub_responses(:get_object, "NoSuchKey")

      expect { target.read_ledger }.to raise_error(described_class::LedgerMissing)
    end

    it "writes the ledger as text/csv" do
      captured = nil
      s3.stub_responses(:put_object, ->(ctx) { captured = ctx.params; {} })

      target.write_ledger("a,b\n")

      expect(captured[:key]).to eq("archives.csv")
      expect(captured[:content_type]).to eq("text/csv")
    end
  end

  describe "#publish_site" do
    it "writes delivery headers into the staging directory before deploying" do
      Dir.mktmpdir do |dir|
        target.publish_site(dir)

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
        expect { failing.publish_site(dir) }.to raise_error(described_class::DeployFailed)
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
