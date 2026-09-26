# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "internal/state_dir"

RSpec.describe StateDir do
  let(:work_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(work_dir) }

  it "is work/state" do
    expect(described_class.path(work_dir)).to eq(File.join(work_dir, "state"))
  end

  describe ".migrate_legacy!" do
    it "moves the internal state left directly under work/ into work/state/, leaving other files alone" do
      File.write(File.join(work_dir, "last_fetch.json"), "{}")
      FileUtils.mkdir_p(File.join(work_dir, "feed_cache"))
      File.write(File.join(work_dir, "feed_cache", "a.json"), "[]")
      File.write(File.join(work_dir, "news_20260714_morning.txt"), "intermediate")

      moved = described_class.migrate_legacy!(work_dir)

      expect(moved.map { |path| File.basename(path) }).to contain_exactly("last_fetch.json", "feed_cache")
      expect(File.read(File.join(work_dir, "state", "last_fetch.json"))).to eq("{}")
      expect(File.read(File.join(work_dir, "state", "feed_cache", "a.json"))).to eq("[]")
      expect(File.exist?(File.join(work_dir, "news_20260714_morning.txt"))).to be true
    end

    it "moves nothing and aborts when the same entry already exists in work/state/" do
      File.write(File.join(work_dir, "last_fetch.json"), "legacy")
      FileUtils.mkdir_p(File.join(work_dir, "state"))
      File.write(File.join(work_dir, "state", "last_fetch.json"), "current")

      expect { described_class.migrate_legacy!(work_dir) }.to raise_error(SystemExit)

      expect(File.read(File.join(work_dir, "last_fetch.json"))).to eq("legacy")
      expect(File.read(File.join(work_dir, "state", "last_fetch.json"))).to eq("current")
    end

    it "does nothing when nothing is left in the legacy place" do
      expect(described_class.migrate_legacy!(work_dir)).to be_empty
    end
  end
end
