# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "internal/news_snapshot"

RSpec.describe NewsSnapshot do
  let(:work_dir) { Dir.mktmpdir }
  let(:at) { Time.utc(2026, 7, 14, 3, 0, 0) }

  after { FileUtils.remove_entry(work_dir) }

  it "round-trips the news and its collection time under work/state/news_snapshots/" do
    described_class.save!(work_dir: work_dir, episode_key: "20260714_morning", news: "1. Title\n", at: at)

    snapshot = described_class.load(work_dir, "20260714_morning")

    expect(snapshot.news).to eq("1. Title\n")
    expect(snapshot.at).to eq(at)
    expect(File.exist?(File.join(work_dir, "state", "news_snapshots", "20260714_morning.json"))).to be true
  end

  it "returns nil when there is no snapshot" do
    expect(described_class.load(work_dir, "20260714_morning")).to be_nil
  end

  it "retain! deletes snapshots of episodes that are not kept" do
    %w[20260714_morning 20260714_afternoon 20260714_evening].each do |key|
      described_class.save!(work_dir: work_dir, episode_key: key, news: key, at: at)
    end

    described_class.retain!(work_dir: work_dir, keep_keys: %w[20260714_afternoon 20260714_evening])

    expect(described_class.load(work_dir, "20260714_morning")).to be_nil
    expect(described_class.load(work_dir, "20260714_evening").news).to eq("20260714_evening")
  end
end
