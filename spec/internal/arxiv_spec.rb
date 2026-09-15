# frozen_string_literal: true

require "spec_helper"
require "time"
require "internal/arxiv"

RSpec.describe Internal::Arxiv do
  describe ".old?" do
    let(:now) { Time.utc(2026, 9, 15) }

    it "does not flag an entry posted in the current month" do
      link = "https://arxiv.org/abs/2609.15989"

      expect(described_class.old?(link, max_age_days: 30, now: now)).to be false
    end

    it "flags an entry posted several months ago" do
      link = "https://arxiv.org/abs/1912.08786"

      expect(described_class.old?(link, max_age_days: 30, now: now)).to be true
    end

    it "does not flag an entry from the previous month when within max_age_days" do
      # 2026-08 の月末(08-31)は now(09-15) から15日前。max_age_days: 30 なら含まれる。
      link = "https://arxiv.org/abs/2608.00001"

      expect(described_class.old?(link, max_age_days: 30, now: now)).to be false
    end

    it "flags an entry from the previous month when max_age_days is smaller than the gap" do
      link = "https://arxiv.org/abs/2608.00001"

      expect(described_class.old?(link, max_age_days: 7, now: now)).to be true
    end

    it "returns false for a non-arXiv link (out of scope, not filtered)" do
      link = "https://example.com/news/123"

      expect(described_class.old?(link, max_age_days: 30, now: now)).to be false
    end

    it "handles a year rollover in the posted month (Dec ID, now in a later year)" do
      link = "https://arxiv.org/abs/2512.00001"
      later_now = Time.utc(2026, 1, 20)

      expect(described_class.old?(link, max_age_days: 30, now: later_now)).to be false
      expect(described_class.old?(link, max_age_days: 7, now: later_now)).to be true
    end
  end
end
