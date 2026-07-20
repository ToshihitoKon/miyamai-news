# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "episode"
require "internal/last_fetch_store"
require "internal/used_news_history"
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
            # extractor は facts と一緒に暫定 used_news も書く。
            File.write(generator.send(:used_news_path), "## 生成AI\n### [Title A](https://example.com/a)\n   要約です。\n   (2026-07-14 / SourceA)\n")
          end
          ["", "", success_status]
        end

        facts_path = generator.digest

        expect(call_count).to eq(2)
        expect(facts_path).to eq(generator.send(:news_facts_path))
        expect(File.read(facts_path)).to include("概要です")
        # digest mode でも暫定 used_news が残る（履歴の元データ）。台本は作らない。
        expect(File.read(generator.send(:used_news_path))).to include("Title A")
        expect(File.exist?(generator.send(:script_path))).to be false
      end
    end
  end

  describe "selector プロンプトへの紹介済みニュース履歴の反映" do
    # selector（1回目の AI 呼び出し）に渡した stdin を捕捉して返す。
    def capture_selector_stdin(generator)
      success = instance_double(Process::Status, success?: true, exitstatus: 0)
      selector_stdin = nil
      call = 0
      allow(Open3).to receive(:capture3) do |*_cmd, **opts|
        call += 1
        if call == 1
          selector_stdin = opts[:stdin_data]
          File.write(generator.send(:news_selected_path), "## 生成AI\n1. Title A\n   https://example.com/a\n   (meta)\n")
        elsif call == 2
          File.write(generator.send(:news_facts_path), "## Title A\n概要です。\n")
        end
        ["", "", success]
      end
      generator.digest
      selector_stdin
    end

    def record_history(episode_key, body)
      path = File.join(work_dir, "news_used_#{episode_key}.txt")
      File.write(path, body)
      UsedNewsHistory.record!(work_dir: work_dir, episode_key: episode_key, used_news_path: path, keep_episodes: 4)
    end

    it "includes the recently used section when history exists" do
      record_history("20260713_evening", "■ 生成AI\n・過去の話題\n   要約テキストです。\n   https://example.com/old\n   (2026-07-13 / OldSource)\n")
      generator = described_class.new(work_dir: work_dir, episode: episode)

      stdin = capture_selector_stdin(generator)

      expect(stdin).to include("<recently_used>")
      expect(stdin).to include("過去の話題")
      # 履歴からは link を落としている。
      expect(stdin).not_to include("https://example.com/old")
    end

    it "omits the section when there is no history" do
      generator = described_class.new(work_dir: work_dir, episode: episode)

      stdin = capture_selector_stdin(generator)

      expect(stdin).not_to include("<recently_used>")
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
              File.write(generator.send(:used_news_path), "## 生成AI\n### [Title A](https://example.com/a)\n   要約です。\n   (2026-07-14 / SourceA)\n")
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
    it "uses the confirmed timestamp" do
      at = Time.utc(2026, 7, 14, 9, 0, 0)
      LastFetchStore.confirm_immediately!(work_dir: work_dir, at: at)
      generator = described_class.new(work_dir: work_dir, episode: episode)

      expect(generator.send(:collect_since)).to eq(at)
    end

    it "falls back to lookback_hours when nothing has been confirmed yet" do
      generator = described_class.new(work_dir: work_dir, episode: episode)

      expect(generator.send(:collect_since)).to eq(now - generator.send(:lookback_hours) * 3600)
    end
  end

  describe "#fetched_news?" do
    it "is true after collecting news for the first time" do
      generator = described_class.new(work_dir: work_dir, episode: episode)

      generator.send(:load_or_collect_news)

      expect(generator.fetched_news?).to be true
    end

    it "is false when an existing news snapshot is reused" do
      generator = described_class.new(work_dir: work_dir, episode: episode)
      File.write(generator.send(:news_collected_path), "1. Title A\n")

      generator.send(:load_or_collect_news)

      expect(generator.fetched_news?).to be false
    end

    it "is false before any collection has run" do
      generator = described_class.new(work_dir: work_dir, episode: episode)

      expect(generator.fetched_news?).to be false
    end

    # digest→synthesize は同一インスタンスで load_or_collect_news を 2 回通り、2 回目は
    # スナップショット再利用になる。それで false に戻ると「新規収集したのに confirmed_at を
    # 進めない」取り違えが起きるので、一度収集したら true を保つ。
    it "stays true on a subsequent reuse within the same instance" do
      generator = described_class.new(work_dir: work_dir, episode: episode)

      generator.send(:load_or_collect_news) # 新規収集
      generator.send(:load_or_collect_news) # スナップショット再利用

      expect(generator.fetched_news?).to be true
    end
  end

  describe "#collect_since_anchor" do
    # 次回の収集 window 起点として保存すべき時刻。新規 entry の seen_at はこの時刻で
    # 記録されるので、実行完了時刻ではなく収集基準時刻(episode.now)でなければ、実行に
    # 時間がかかった場合に seen_at がその間に刻まれた記事を次回取りこぼす。
    it "returns the collection anchor (episode.now), not the wall clock at completion" do
      generator = described_class.new(work_dir: work_dir, episode: episode)

      expect(generator.collect_since_anchor).to eq(now)
    end
  end

  describe "pending fetch resolution timing" do
    # 前回 pending の確定/ロールバック確認は「新規 fetch が実際に走る直前」だけに出したい。
    # --script-only の後にフラグなしで synthesize へ進むと、収集は既存スナップショットの
    # 再利用になり fetch しないので、確認が出てはいけない。解決自体は LastFetchStore に委ねる。
    it "resolves pending exactly once when news is actually fetched" do
      allow(LastFetchStore).to receive(:resolve_pending!)
      generator = described_class.new(work_dir: work_dir, episode: episode, auto_confirm: true)

      generator.send(:load_or_collect_news)

      expect(LastFetchStore).to have_received(:resolve_pending!).with(work_dir: work_dir, auto_confirm: true).once
    end

    it "does not resolve pending when an existing news snapshot is reused" do
      allow(LastFetchStore).to receive(:resolve_pending!)
      generator = described_class.new(work_dir: work_dir, episode: episode)
      File.write(generator.send(:news_collected_path), "1. Title A\n")

      generator.send(:load_or_collect_news)

      expect(LastFetchStore).not_to have_received(:resolve_pending!)
    end
  end
end
