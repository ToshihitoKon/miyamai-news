# frozen_string_literal: true

require "spec_helper"
require "internal/relative_path"

RSpec.describe Internal::RelativePath do
  describe ".from_root" do
    it "strips the ROOT_DIR prefix from an absolute path under it" do
      path = File.join(Config::ROOT_DIR, "dist", "miyamai_news_20260915_morning.mp3")

      expect(described_class.from_root(path)).to eq("dist/miyamai_news_20260915_morning.mp3")
    end

    it "returns an absolute path outside ROOT_DIR unchanged" do
      path = "/tmp/somewhere/config.yaml"

      expect(described_class.from_root(path)).to eq(path)
    end

    it "is idempotent for a path that is already relative" do
      path = "work/news_facts_20260915_morning.txt"

      expect(described_class.from_root(path)).to eq(path)
    end
  end
end
