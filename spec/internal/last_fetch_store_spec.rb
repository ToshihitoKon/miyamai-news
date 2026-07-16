# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "internal/last_fetch_store"

RSpec.describe LastFetchStore do
  let(:work_dir) { Dir.mktmpdir }
  let(:store) { described_class.new(work_dir: work_dir) }

  after { FileUtils.remove_entry(work_dir) }

  describe "#record_reached!" do
    it "advances the reached mode and every lower mode to the same timestamp" do
      at = Time.utc(2026, 7, 14, 9, 0, 0)

      store.record_reached!(mode: "synthesize", at: at)

      data = store.load
      expect(data["digest"]).to eq(at.iso8601)
      expect(data["synthesize"]).to eq(at.iso8601)
      expect(data).not_to have_key("publish")
    end

    it "does not roll back a higher mode when a lower mode is reached later" do
      earlier = Time.utc(2026, 7, 14, 9, 0, 0)
      later = Time.utc(2026, 7, 14, 10, 0, 0)
      store.record_reached!(mode: "publish", at: earlier)

      store.record_reached!(mode: "digest", at: later)

      data = store.load
      expect(data["digest"]).to eq(later.iso8601)
      expect(data["publish"]).to eq(earlier.iso8601)
    end
  end

  describe "#load" do
    it "returns an empty hash when neither last_fetch.json nor the legacy file exists" do
      expect(store.load).to eq({})
    end

    it "migrates the legacy last_fetch.txt into last_fetch.json for every mode" do
      at = Time.utc(2026, 7, 10, 8, 0, 0)
      File.write(store.legacy_path, at.iso8601)

      data = store.load

      expect(data.values).to all(eq(at.iso8601))
      expect(File.exist?(store.legacy_path)).to be false
      expect(File.exist?(store.path)).to be true
    end

    it "leaves a corrupt legacy file untouched and returns an empty hash" do
      File.write(store.legacy_path, "not-a-timestamp")

      expect(store.load).to eq({})
      expect(File.exist?(store.legacy_path)).to be true
    end
  end
end
