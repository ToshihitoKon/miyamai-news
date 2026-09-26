# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "internal/last_fetch_store"

RSpec.describe LastFetchStore do
  let(:work_dir) { Dir.mktmpdir }
  let(:t1) { Time.utc(2026, 7, 13, 21, 0, 0) }
  let(:t2) { Time.utc(2026, 7, 14, 3, 0, 0) }
  let(:t3) { Time.utc(2026, 7, 14, 9, 0, 0) }
  let(:t4) { Time.utc(2026, 7, 14, 15, 0, 0) }

  after { FileUtils.remove_entry(work_dir) }

  def commit(key, at) = described_class.commit!(work_dir: work_dir, episode_key: key, at: at)
  def episodes = described_class.commits(work_dir).map { |c| c["episode"] }

  it "stores the commits in work/state/last_fetch.json" do
    commit("20260714_morning", t1)

    expect(described_class.path(work_dir)).to eq(File.join(work_dir, "state", "last_fetch.json"))
    expect(JSON.parse(File.read(described_class.path(work_dir))))
      .to eq("commits" => [{ "episode" => "20260714_morning", "at" => t1.iso8601 }])
  end

  describe ".since_for" do
    it "is nil when nothing has been committed" do
      expect(described_class.since_for(work_dir, "20260714_morning")).to be_nil
    end

    it "is the collection time of the latest committed episode before the given one" do
      commit("20260714_morning", t1)
      commit("20260714_afternoon", t2)

      expect(described_class.since_for(work_dir, "20260714_evening")).to eq(t2)
    end

    it "skips the given episode itself when it is the latest commit (regenerating it)" do
      commit("20260714_morning", t1)
      commit("20260714_afternoon", t2)

      expect(described_class.since_for(work_dir, "20260714_afternoon")).to eq(t1)
    end

    it "refuses an episode older than the latest committed one" do
      commit("20260714_evening", t3)

      expect { described_class.since_for(work_dir, "20260714_afternoon") }
        .to raise_error(described_class::OlderEpisodeError, /older than the latest committed episode 20260714_evening/)
    end
  end

  describe ".commit!" do
    it "keeps only the latest KEEP_COMMITS episodes, newest first" do
      commit("20260714_morning", t1)
      commit("20260714_afternoon", t2)
      commit("20260714_evening", t3)
      commit("20260714_midnight", t4)

      expect(episodes).to eq(%w[20260714_midnight 20260714_evening 20260714_afternoon])
    end

    it "replaces the commit of the same episode instead of stacking it" do
      commit("20260714_morning", t1)
      commit("20260714_afternoon", t2)

      commit("20260714_afternoon", t3)

      expect(episodes).to eq(%w[20260714_afternoon 20260714_morning])
      expect(described_class.latest_commit(work_dir)["at"]).to eq(t3.iso8601)
    end

    it "refuses an episode older than the latest committed one" do
      commit("20260714_evening", t3)

      expect { commit("20260714_morning", t1) }.to raise_error(described_class::OlderEpisodeError)
      expect(episodes).to eq(%w[20260714_evening])
    end

    it "orders commits by episode, not by the order they were written" do
      commit("20260713_midnight", t1)
      commit("20260714_morning", t2)

      expect(episodes).to eq(%w[20260714_morning 20260713_midnight])
    end
  end

  describe "legacy last_fetch.json (confirmed_at only)" do
    before do
      FileUtils.mkdir_p(File.dirname(described_class.path(work_dir)))
      File.write(described_class.path(work_dir), JSON.generate(
        "confirmed_at" => t1.iso8601, "pending_at" => t2.iso8601, "pending_episode" => "20260714_afternoon",
        "rollback_at" => nil, "last_op" => nil
      ))
    end

    it "treats confirmed_at as the oldest commit, so it becomes the start of the next collection" do
      expect(described_class.since_for(work_dir, "20260714_afternoon")).to eq(t1)
    end

    it "ignores the pending window and rewrites the file in the new format on the next commit" do
      commit("20260714_afternoon", t3)

      expect(episodes).to eq(%w[20260714_afternoon legacy])
      expect(JSON.parse(File.read(described_class.path(work_dir))).keys).to eq(["commits"])
    end
  end

  it "aborts instead of overwriting a last_fetch.json that is valid JSON but not an object" do
    FileUtils.mkdir_p(File.dirname(described_class.path(work_dir)))
    File.write(described_class.path(work_dir), "[]")

    expect { described_class.commits(work_dir) }.to raise_error(SystemExit)
  end

  it "treats an unparsable last_fetch.json as empty" do
    FileUtils.mkdir_p(File.dirname(described_class.path(work_dir)))
    File.write(described_class.path(work_dir), "{broken")

    expect(described_class.commits(work_dir)).to be_empty
  end
end
