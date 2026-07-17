# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "episode"
require "internal/last_fetch_store"
require "script_generator"

RSpec.describe ScriptGenerator do
  let(:work_dir) { Dir.mktmpdir }
  let(:now) { Time.utc(2026, 7, 14, 12, 0, 0) } # afternoon slot
  let(:episode) { Episode.new(now: now) }

  let(:news_items) do
    [
      { link: "https://example.com/a", title: "Title A", date: "2026-07-14T00:00:00Z", seen_at: now.iso8601, extra: nil },
      { link: "https://example.com/b", title: "Title B", date: "2026-07-14T00:00:00Z", seen_at: now.iso8601, extra: nil }
    ]
  end

  let(:fake_feed_cache) { instance_double(FeedCache, fetch: news_items) }

  before do
    allow(FeedCache).to receive(:new).and_return(fake_feed_cache)
  end

  after { FileUtils.remove_entry(work_dir) }

  describe "#collect_news" do
    context "FeedCache mocked" do
      context "success" do
        it "collects entries from the injected FeedCache for every configured source" do
          generator = described_class.new(work_dir: work_dir, episode: episode)

          body = generator.send(:collect_news)

          expect(fake_feed_cache).to have_received(:fetch).exactly(generator.send(:sources).size).times
          expect(body).to include("Title A")
        end
      end

      context "failure" do
        it "aborts news collection when FeedCache raises FetchError" do
          allow(fake_feed_cache).to receive(:fetch).and_raise(FeedCache::FetchError, "boom")
          generator = described_class.new(work_dir: work_dir, episode: episode)

          expect { generator.send(:collect_news) }.to raise_error(SystemExit)
        end
      end
    end
  end

  describe "#digest" do
    context "AI CLI mocked via Open3.capture3" do
      it "stops after selector and extractor, without writing script/tts_script" do
        generator = described_class.new(work_dir: work_dir, episode: episode)
        success_status = instance_double(Process::Status, success?: true, exitstatus: 0)
        call_count = 0

        allow(Open3).to receive(:capture3) do |*_cmd, **_opts|
          call_count += 1
          case call_count
          when 1
            File.write(generator.send(:news_selected_path), "## 生成AI\n1. Title A\n   https://example.com/a\n   (meta)\n")
          when 2
            File.write(generator.send(:news_facts_path), "## Title A\n概要です。\n")
          end
          ["", "", success_status]
        end

        facts_path = generator.digest

        expect(call_count).to eq(2)
        expect(facts_path).to eq(generator.send(:news_facts_path))
        expect(File.read(facts_path)).to include("概要です")
        expect(File.exist?(generator.send(:script_path))).to be false
      end
    end
  end

  describe "#generate" do
    context "AI CLI mocked via Open3.capture3" do
      context "success" do
        it "runs the full pipeline without invoking a real claude binary" do
          generator = described_class.new(work_dir: work_dir, episode: episode)
          success_status = instance_double(Process::Status, success?: true, exitstatus: 0)
          call_count = 0

          allow(Open3).to receive(:capture3) do |*_cmd, **_opts|
            call_count += 1
            case call_count
            when 1
              File.write(generator.send(:news_selected_path), "## 生成AI\n1. Title A\n   https://example.com/a\n   (meta)\n")
            when 2
              File.write(generator.send(:news_facts_path), "## Title A\n概要です。\n")
            when 3
              File.write(generator.send(:script_path), "宮舞モカです。こんにちは、今日のニュースです。\n")
              File.write(generator.send(:used_news_path), "1. Title A\nhttps://example.com/a\n")
            when 4
              File.write(generator.send(:tts_script_path), "宮舞モカです。こんにちは、今日のニュースです（整形済み）。\n")
            end
            ["", "", success_status]
          end

          tts_path = generator.generate

          expect(call_count).to eq(4)
          expect(File.read(tts_path)).to include("整形済み")
          expect(File.read(generator.used_news_file)).to include("Title A")
          expect(Open3).to have_received(:capture3).with(
            "claude", "-p", "--model", "claude-sonnet-5", "--effort", "xhigh", "--allowedTools", "Write",
            stdin_data: an_instance_of(String)
          )
        end
      end

      context "failure" do
        it "aborts when the AI CLI exits with a failure status" do
          generator = described_class.new(work_dir: work_dir, episode: episode)
          failure_status = instance_double(Process::Status, success?: false, exitstatus: 1)
          allow(Open3).to receive(:capture3).and_return(["", "boom", failure_status])

          expect { generator.generate }.to raise_error(SystemExit)
        end
      end

      context "ai_agent.effort が未設定" do
        it "omits --effort instead of passing nil to Open3.capture3" do
          allow(Config.ai_agent).to receive(:effort).and_return(nil)
          generator = described_class.new(work_dir: work_dir, episode: episode)
          success_status = instance_double(Process::Status, success?: true, exitstatus: 0)

          allow(Open3).to receive(:capture3) do |*_cmd, **_opts|
            File.write(generator.send(:news_selected_path), "## 生成AI\n1. Title A\n   https://example.com/a\n   (meta)\n")
            ["", "", success_status]
          end

          generator.send(:select_news, generator.send(:collect_news))

          expect(Open3).to have_received(:capture3).with(
            "claude", "-p", "--model", "claude-sonnet-5", "--allowedTools", "Write",
            stdin_data: an_instance_of(String)
          )
        end
      end
    end
  end

  describe "#collect_since" do
    it "uses the recorded timestamp for the current pipeline.mode" do
      at = Time.utc(2026, 7, 14, 9, 0, 0)
      LastFetchStore.new(work_dir: work_dir).record_reached!(mode: Config.mode, at: at)
      generator = described_class.new(work_dir: work_dir, episode: episode)

      expect(generator.send(:collect_since)).to eq(at)
    end

    it "falls back to lookback_hours when nothing has been recorded yet" do
      generator = described_class.new(work_dir: work_dir, episode: episode)

      expect(generator.send(:collect_since)).to eq(now - generator.send(:lookback_hours) * 3600)
    end
  end
end
