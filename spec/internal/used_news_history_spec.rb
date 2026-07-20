# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "internal/used_news_history"

RSpec.describe UsedNewsHistory do
  let(:work_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(work_dir) }

  # writer.prompt.erb の used_news 形式（## カテゴリ / ### [タイトル](link) / 要約 /
  # (date/source)）のサンプル。link はタイトル行に内包される。
  def used_news_text(title:, link:)
    <<~USED
      ## 生成AI
      ### [#{title}](#{link})
         推論性能が向上し、コーディング用途向けの新モデル。
         (2026-07-20 / OpenAI)
    USED
  end

  # ScriptGenerator が work/ に落とす used ファイルを模して置く。
  def put_used_file(episode_key, content)
    path = File.join(work_dir, "news_used_#{episode_key}.txt")
    File.write(path, content)
    path
  end

  def record(episode_key, content, keep_episodes: 4)
    described_class.record!(
      work_dir: work_dir, episode_key: episode_key,
      used_news_path: put_used_file(episode_key, content), keep_episodes: keep_episodes
    )
  end

  def history_files
    Dir.glob(File.join(described_class.dir(work_dir), "*.txt")).map { |p| File.basename(p, ".txt") }
  end

  describe ".record!" do
    it "copies the used_news, dropping the URL from the title line but keeping the title" do
      record("20260720_afternoon", used_news_text(title: "GPT-5.6 発表", link: "https://openai.com/gpt56"))

      saved = File.read(File.join(described_class.dir(work_dir), "20260720_afternoon.txt"))
      # ### [タイトル](URL) → ### タイトル（URL だけ落ちてタイトルは残る）。
      expect(saved).to include("### GPT-5.6 発表")
      expect(saved).to include("推論性能が向上")
      expect(saved).to include("(2026-07-20 / OpenAI)")
      expect(saved).not_to include("https://openai.com/gpt56")
      expect(saved).not_to include("](")
    end

    it "does nothing when the used_news file is absent" do
      described_class.record!(
        work_dir: work_dir, episode_key: "20260720_afternoon",
        used_news_path: File.join(work_dir, "missing.txt"), keep_episodes: 4
      )

      expect(history_files).to be_empty
    end

    it "overwrites the same episode_key idempotently" do
      record("20260720_afternoon", used_news_text(title: "初回", link: "https://a"))
      record("20260720_afternoon", used_news_text(title: "書き直し", link: "https://a"))

      expect(history_files).to eq(["20260720_afternoon"])
      saved = File.read(File.join(described_class.dir(work_dir), "20260720_afternoon.txt"))
      expect(saved).to include("書き直し")
      expect(saved).not_to include("初回")
    end

    it "keeps only the newest keep_episodes, dropping the oldest by (date_tag, slot)" do
      # 記録順をわざと時系列とずらして入れ、slot 混在でも正しく並ぶことを見る。
      record("20260720_afternoon", used_news_text(title: "afternoon", link: "https://a"), keep_episodes: 4)
      record("20260719_midnight", used_news_text(title: "prev-midnight", link: "https://b"), keep_episodes: 4)
      record("20260720_midnight", used_news_text(title: "midnight", link: "https://c"), keep_episodes: 4)
      record("20260720_morning", used_news_text(title: "morning", link: "https://d"), keep_episodes: 4)
      record("20260720_evening", used_news_text(title: "evening", link: "https://e"), keep_episodes: 4)

      # 最古の 20260719_midnight が落ちる。
      expect(history_files).to contain_exactly(
        "20260720_morning", "20260720_afternoon", "20260720_evening", "20260720_midnight"
      )
    end
  end

  describe ".render_for_prompt" do
    it "returns an empty string when no history exists" do
      expect(described_class.render_for_prompt(work_dir, 4)).to eq("")
    end

    it "concatenates the recent episodes newest first" do
      record("20260720_morning", used_news_text(title: "朝の話題", link: "https://a"))
      record("20260720_evening", used_news_text(title: "夜の話題", link: "https://b"))

      rendered = described_class.render_for_prompt(work_dir, 4)

      expect(rendered).to include("朝の話題")
      expect(rendered).to include("夜の話題")
      # 新しい順（evening が morning より先）。
      expect(rendered.index("夜の話題")).to be < rendered.index("朝の話題")
      # link は履歴から除かれている。
      expect(rendered).not_to include("https://")
    end

    it "limits to keep_episodes most recent" do
      record("20260720_morning", used_news_text(title: "朝ニュース", link: "https://a"), keep_episodes: 10)
      record("20260720_afternoon", used_news_text(title: "昼ニュース", link: "https://b"), keep_episodes: 10)
      record("20260720_evening", used_news_text(title: "夜ニュース", link: "https://c"), keep_episodes: 10)

      rendered = described_class.render_for_prompt(work_dir, 2)

      expect(rendered).to include("夜ニュース")
      expect(rendered).to include("昼ニュース")
      expect(rendered).not_to include("朝ニュース") # morning は 3 件目なので除外
    end
  end
end
