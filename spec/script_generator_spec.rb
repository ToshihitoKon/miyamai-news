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

          body = generator.send(:collect_news, now - 3600)

          expect(fake_feed_cache).to have_received(:fetch).exactly(generator.send(:sources).size).times
          expect(body).to include("Title A")
        end
      end

      context "failure" do
        it "aborts news collection when FeedCache raises FetchError" do
          allow(fake_feed_cache).to receive(:fetch).and_raise(FeedCache::FetchError, "boom")
          generator = described_class.new(work_dir: work_dir, episode: episode)

          expect { generator.send(:collect_news, now - 3600) }.to raise_error(SystemExit)
        end
      end
    end

    describe "#collect_stats" do
      it "計算後、全ソース分の per_source と dedup 前後の合計を保持する" do
        generator = described_class.new(work_dir: work_dir, episode: episode)
        sources = generator.send(:sources)

        generator.send(:collect_news, now - 3600)
        stats = generator.collect_stats

        expect(stats.per_source.size).to eq(sources.size)
        expect(stats.per_source.map(&:first)).to eq(sources.map(&:name))
        expect(stats.total_before_dedup).to eq(stats.per_source.sum { |_name, count| count })
      end

      it "ソース間でタイトルが重複する場合、dedup前合計がdedup後合計を上回る" do
        # fake_feed_cache は全ソースに同じ2件（Title A/B）を返すため、
        # 複数ソースを持つ fixture では既にタイトル重複が起きている。
        generator = described_class.new(work_dir: work_dir, episode: episode)

        generator.send(:collect_news, now - 3600)
        stats = generator.collect_stats

        expect(stats.total_before_dedup).to be > stats.total_after_dedup
        expect(stats.total_after_dedup).to eq(news_items.size)
      end

      it "全ソース0件のときも per_source の各要素が [name, 0] のまま欠落しない" do
        allow(fake_feed_cache).to receive(:fetch).and_return([])
        generator = described_class.new(work_dir: work_dir, episode: episode)
        sources = generator.send(:sources)

        generator.send(:collect_news, now - 3600)
        stats = generator.collect_stats

        expect(stats.per_source).to eq(sources.map { |src| [src.name, 0] })
        expect(stats.total_before_dedup).to eq(0)
        expect(stats.total_after_dedup).to eq(0)
      end

      it "news_collected_path の既存スナップショットを再利用する場合は nil のまま" do
        generator = described_class.new(work_dir: work_dir, episode: episode)
        File.write(generator.send(:news_collected_path), "1. Title A\n")
        File.write(generator.send(:news_collected_at_path), now.iso8601)

        generator.send(:load_or_collect_news)

        expect(generator.collect_stats).to be_nil
      end
    end

    describe "#report_collect_stats（収集直後の出力）" do
      it "load_or_collect_news 完了直後にソース別・合計行を出力する" do
        generator = described_class.new(work_dir: work_dir, episode: episode)
        sources = generator.send(:sources)
        messages = []
        allow(generator).to receive(:warn) { |msg| messages << msg }

        generator.send(:load_or_collect_news)

        news_index = messages.index { |m| m.start_with?("news: ") }
        expect(news_index).not_to be_nil
        sources.each do |src|
          expect(messages[news_index + 1..]).to include("new articles from #{src.name}: #{news_items.size}")
        end
        expect(messages.last).to match(/\Anew articles total: \d+ \(\d+ before dedup\)\z/)
      end

      it "news_collected_path の既存スナップショットを再利用する場合は件数行を出力しない" do
        generator = described_class.new(work_dir: work_dir, episode: episode)
        File.write(generator.send(:news_collected_path), "1. Title A\n")
        File.write(generator.send(:news_collected_at_path), now.iso8601)
        messages = []
        allow(generator).to receive(:warn) { |msg| messages << msg }

        generator.send(:load_or_collect_news)

        expect(messages.grep(/\Anew articles/)).to be_empty
      end
    end
  end

  describe "#collect_source" do
    let(:old_arxiv_link) { "https://arxiv.org/abs/1912.08786" }
    let(:fresh_arxiv_link) { "https://arxiv.org/abs/2609.15989" }
    let(:arxiv_items) do
      [
        { link: old_arxiv_link, title: "Old paper", date: nil, seen_at: now.iso8601, extra: nil },
        { link: fresh_arxiv_link, title: "Fresh paper", date: nil, seen_at: now.iso8601, extra: nil }
      ]
    end

    def src(max_age_days: nil)
      attrs = { name: "arXiv cs.AI", url: "http://export.arxiv.org/rss/cs.AI" }
      attrs[:max_age_days] = max_age_days if max_age_days
      Internal::Config::RssFeedSource.new(attrs)
    end

    it "drops entries older than max_age_days when the source configures it" do
      allow(fake_feed_cache).to receive(:fetch).and_return(arxiv_items)
      generator = described_class.new(work_dir: work_dir, episode: episode)

      result = generator.send(:collect_source, src(max_age_days: 30), now - 3600)

      expect(result.map { |i| i[:link] }).to eq([fresh_arxiv_link])
    end

    it "keeps every entry when the source does not configure max_age_days (no other feed is affected)" do
      allow(fake_feed_cache).to receive(:fetch).and_return(arxiv_items)
      generator = described_class.new(work_dir: work_dir, episode: episode)

      result = generator.send(:collect_source, src, now - 3600)

      expect(result.map { |i| i[:link] }).to contain_exactly(old_arxiv_link, fresh_arxiv_link)
    end

    it "judges max_age_days against the regenerated episode's collection time when selecting from the cache" do
      allow(fake_feed_cache).to receive(:cached_window).and_return(arxiv_items)
      generator = described_class.new(work_dir: work_dir, episode: episode)
      long_after = now + (400 * 86_400)

      result = generator.send(:collect_source, src(max_age_days: 30), now - 3600, long_after)

      expect(fake_feed_cache).to have_received(:cached_window).with(anything, since: now - 3600, until_at: long_after)
      expect(result).to be_empty
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
            # extractor は facts と一緒に暫定 used_news（別パス）も書く。
            File.write(generator.send(:provisional_used_news_path), "## 生成AI\n### [Title A](https://example.com/a)\n   要約です。\n   (2026-07-14 / SourceA)\n")
          end
          ["", "", success_status]
        end

        facts_path = generator.digest

        expect(call_count).to eq(2)
        expect(facts_path).to eq(generator.send(:news_facts_path))
        expect(File.read(facts_path)).to include("概要です")
        # digest mode でも暫定 used_news が残る（履歴の元データ）。台本は作らない。
        expect(File.read(generator.send(:provisional_used_news_path))).to include("Title A")
        expect(File.exist?(generator.send(:script_path))).to be false
      end
    end
  end

  describe "#digest でのタイムアウト検知後のクリーンアップ" do
    context "extractor が対象ファイルを書いた直後に agy が print timeout した場合" do
      it "deletes the partial news_facts file before aborting, so a retry does not reuse it" do
        generator = described_class.new(work_dir: work_dir, episode: episode)
        success_status = instance_double(Process::Status, success?: true, exitstatus: 0)
        call_count = 0

        allow(Open3).to receive(:capture3) do |*_cmd, **_opts|
          call_count += 1
          case call_count
          when 1
            File.write(generator.send(:news_selected_path), "## 生成AI\n1. Title A\n   https://example.com/a\n   (meta)\n")
            ["", "", success_status]
          when 2
            File.write(generator.send(:news_facts_path), "truncated by agy before it timed out")
            timeout_status = instance_double(Process::Status, success?: true, exitstatus: 0)
            ["", "[agy] print timeout after 5m0s with turn in progress; returning partial output\n", timeout_status]
          end
        end

        expect { generator.digest }.to raise_error(SystemExit)

        expect(File.exist?(generator.send(:news_facts_path))).to be false
      end
    end
  end

  describe "#digest と #generate を同一インスタンスで連続実行した場合" do
    # pipeline.rb の run_full は同一 generator に対して digest → generate の順で呼ぶ。
    # digest_news は両方から呼ばれる冪等関数なので、メモ化しないと2回目の呼び出しで
    # 「今まさに自分が生成したファイル」を reuse と誤って報告してしまう。
    it "digest_news の中身を再実行せず、facts抽出までのAI呼び出しは1回で済む" do
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

      expect(generator).not_to receive(:warn).with(/\Areuse: /)

      generator.digest
      generator.generate

      expect(call_count).to eq(4)
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

    it "leaves out the history of the episode being regenerated" do
      record_history("20260713_evening", "■ 生成AI\n・前の回の話題\n")
      record_history("#{episode.date_tag}_#{episode.slot}", "■ 生成AI\n・この回自身の話題\n")
      generator = described_class.new(work_dir: work_dir, episode: episode)

      stdin = capture_selector_stdin(generator)

      expect(stdin).to include("前の回の話題")
      expect(stdin).not_to include("この回自身の話題")
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
          expect(Open3).to have_received(:capture3).at_least(:once).with(
            "claude", "-p", "--model", "claude-sonnet-5", "--effort", "xhigh",
            "--allowedTools", "Read Write WebFetch",
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

        # issue #83: extractor が書いた暫定版が確定版パスと同じだと、writer が used_news を
        # 書き損ねても existence チェックを素通りしてしまっていた。暫定版を別パスにしたので、
        # writer が確定版パスに書かなければ abort することを確認する。
        it "aborts when the writer writes the script but skips the finalized used_news" do
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
              File.write(generator.send(:provisional_used_news_path), "## 生成AI\n### [Title A](https://example.com/a)\n   要約です。\n   (2026-07-14 / SourceA)\n")
            when 3
              # writer は script だけ書いて used_news（確定版）への Write を怠る。
              File.write(generator.send(:script_path), "宮舞モカです。こんにちは、今日のニュースです。\n")
            end
            ["", "", success_status]
          end

          expect { generator.generate }.to raise_error(SystemExit)
          expect(File.exist?(generator.send(:used_news_path))).to be false
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

          generator.send(:load_or_collect_news)
          generator.send(:select_news)

          expect(Open3).to have_received(:capture3).with(
            "claude", "-p", "--model", "claude-sonnet-5", "--allowedTools", "Read Write WebFetch",
            stdin_data: an_instance_of(String)
          )
        end
      end
    end
  end

  describe "#dedup_by_title" do
    def dedup(items)
      described_class.new(work_dir: work_dir, episode: episode).send(:dedup_by_title, items)
    end

    it "prefers the priority: high entry even when it appears later in the input" do
      low_first = { title: "Same Title", source: "SourceLow", priority: "low" }
      high_later = { title: "Same Title", source: "SourceHigh", priority: "high" }

      result = dedup([low_first, high_later])

      expect(result).to contain_exactly(high_later)
    end

    it "prefers an unspecified-priority entry over a priority: low entry regardless of order" do
      low_first = { title: "Same Title", source: "SourceLow", priority: "low" }
      unspecified_later = { title: "Same Title", source: "SourceNormal" }

      expect(dedup([low_first, unspecified_later])).to contain_exactly(unspecified_later)
      expect(dedup([unspecified_later, low_first])).to contain_exactly(unspecified_later)
    end

    it "keeps the first entry when priorities are tied" do
      first = { title: "Same Title", source: "SourceA", priority: "high" }
      second = { title: "Same Title", source: "SourceB", priority: "high" }

      expect(dedup([first, second])).to contain_exactly(first)
    end

    it "preserves the first-appearance order of each title group in the output" do
      title_a = { title: "Title A", source: "SourceA" }
      title_b_low = { title: "Title B", source: "SourceLow", priority: "low" }
      title_b_high = { title: "Title B", source: "SourceHigh", priority: "high" }

      result = dedup([title_a, title_b_low, title_b_high])

      expect(result).to eq([title_a, title_b_high])
    end
  end

  describe "収集 window" do
    def collect(generator) = generator.send(:load_or_collect_news)

    def commit(key, at) = LastFetchStore.commit!(work_dir: work_dir, episode_key: key, at: at)

    it "fetches since the previous episode's collection time and records this collection time" do
      morning_at = Time.utc(2026, 7, 13, 21, 0, 0)
      commit("20260714_morning", morning_at)
      generator = described_class.new(work_dir: work_dir, episode: episode)

      collect(generator)

      expect(fake_feed_cache).to have_received(:fetch).with(anything, hash_including(since: morning_at)).at_least(:once)
      expect(generator.collected_at).to eq(now)
    end

    it "falls back to lookback_hours when nothing has been committed yet" do
      generator = described_class.new(work_dir: work_dir, episode: episode)

      collect(generator)

      expect(fake_feed_cache).to have_received(:fetch)
        .with(anything, hash_including(since: now - (generator.send(:lookback_hours) * 3600))).at_least(:once)
    end

    it "regenerating the latest committed episode selects its window from the cache without fetching" do
      morning_at = Time.utc(2026, 7, 13, 21, 0, 0)
      afternoon_at = Time.utc(2026, 7, 14, 3, 0, 0)
      commit("20260714_morning", morning_at)
      commit("20260714_afternoon", afternoon_at)
      allow(fake_feed_cache).to receive(:cached_window).and_return(news_items)
      generator = described_class.new(work_dir: work_dir, episode: episode)

      news = collect(generator)

      expect(fake_feed_cache).not_to have_received(:fetch)
      expect(fake_feed_cache).to have_received(:cached_window)
        .with(anything, since: morning_at, until_at: afternoon_at).exactly(generator.send(:sources).size).times
      expect(news).to include("Title A")
      expect(generator.collected_at).to eq(afternoon_at)
    end

    it "regenerating the only committed episode selects from lookback_hours before its collection time" do
      afternoon_at = Time.utc(2026, 7, 14, 3, 0, 0)
      commit("20260714_afternoon", afternoon_at)
      allow(fake_feed_cache).to receive(:cached_window).and_return(news_items)
      generator = described_class.new(work_dir: work_dir, episode: episode)

      collect(generator)

      expect(fake_feed_cache).to have_received(:cached_window)
        .with(anything, since: afternoon_at - (generator.send(:lookback_hours) * 3600), until_at: afternoon_at).at_least(:once)
    end

    it "aborts for an episode older than the latest committed one" do
      commit("20260714_evening", now + 3600)
      generator = described_class.new(work_dir: work_dir, episode: episode)

      expect { collect(generator) }.to raise_error(SystemExit)
      expect(fake_feed_cache).not_to have_received(:fetch)
    end

    it "aborts when news_*.txt exists without its collection time (left over from before this change)" do
      generator = described_class.new(work_dir: work_dir, episode: episode)
      File.write(generator.send(:news_collected_path), "1. Title A\n")

      expect { collect(generator) }.to raise_error(SystemExit)
    end

    it "reuses news_*.txt and its collection time without fetching again" do
      generator = described_class.new(work_dir: work_dir, episode: episode)
      collect(generator)

      reused = described_class.new(work_dir: work_dir, episode: episode)
      reused.send(:load_or_collect_news)

      expect(fake_feed_cache).to have_received(:fetch).exactly(generator.send(:sources).size).times
      expect(reused.collected_at).to eq(now)
    end
  end

  describe ".record_used_news_history!" do
    # 確定版（writer 到達後）があればそれを、無ければ暫定版（extractor のみ到達した
    # digest mode）を履歴へ記録する。旧「同一パスへの上書き」の代替となるフォールバック。
    it "records the finalized used_news when it exists" do
      episode_key = "20260714_afternoon"
      File.write(described_class.provisional_used_news_path(work_dir, episode_key),
        "## 生成AI\n### [暫定](https://example.com/provisional)\n   暫定要約。\n   (2026-07-14 / SourceA)\n")
      File.write(described_class.used_news_path(work_dir, episode_key),
        "## 生成AI\n### [確定](https://example.com/final)\n   確定要約。\n   (2026-07-14 / SourceA)\n")

      described_class.record_used_news_history!(work_dir: work_dir, episode_key: episode_key)

      saved = File.read(File.join(UsedNewsHistory.dir(work_dir), "#{episode_key}.txt"))
      expect(saved).to include("確定要約")
      expect(saved).not_to include("暫定要約")
    end

    it "falls back to the provisional used_news when the finalized one was never written" do
      episode_key = "20260714_afternoon"
      File.write(described_class.provisional_used_news_path(work_dir, episode_key),
        "## 生成AI\n### [暫定](https://example.com/provisional)\n   暫定要約。\n   (2026-07-14 / SourceA)\n")

      described_class.record_used_news_history!(work_dir: work_dir, episode_key: episode_key)

      saved = File.read(File.join(UsedNewsHistory.dir(work_dir), "#{episode_key}.txt"))
      expect(saved).to include("暫定要約")
    end

    it "does nothing when neither file exists" do
      described_class.record_used_news_history!(work_dir: work_dir, episode_key: "20260714_afternoon")

      expect(Dir.glob(File.join(UsedNewsHistory.dir(work_dir), "*.txt"))).to be_empty
    end
  end
end
