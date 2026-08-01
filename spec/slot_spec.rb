# frozen_string_literal: true

require "spec_helper"
require "slot"

RSpec.describe Slot do
  describe ".for" do
    # DAY_START_HOUR(5) 起点で 6 時間ずつ 4 分割した境界の直前・直後を確認する。
    {
      4 => "midnight",
      5 => "morning",
      10 => "morning",
      11 => "afternoon",
      16 => "afternoon",
      17 => "evening",
      22 => "evening",
      23 => "midnight",
      0 => "midnight"
    }.each do |hour, expected_slot|
      it "returns #{expected_slot.inspect} at hour #{hour}" do
        time = Time.utc(2026, 7, 20, hour, 0, 0)

        expect(Slot.for(time)).to eq(expected_slot)
      end
    end
  end

  describe ".broadcast_date" do
    it "keeps the same date at and after DAY_START_HOUR(5:00)" do
      expect(Slot.broadcast_date(Time.utc(2026, 7, 20, 5, 0, 0))).to eq(Date.new(2026, 7, 20))
    end

    it "keeps the same date late at night (23:00)" do
      expect(Slot.broadcast_date(Time.utc(2026, 7, 20, 23, 0, 0))).to eq(Date.new(2026, 7, 20))
    end

    it "rolls back to the previous day just after midnight (0:00)" do
      expect(Slot.broadcast_date(Time.utc(2026, 7, 20, 0, 0, 0))).to eq(Date.new(2026, 7, 19))
    end

    it "rolls back to the previous day just before DAY_START_HOUR (4:00)" do
      expect(Slot.broadcast_date(Time.utc(2026, 7, 20, 4, 0, 0))).to eq(Date.new(2026, 7, 19))
    end
  end

  describe ".ja_label_from_filename" do
    it "maps each slot suffix to its Japanese label" do
      expect(Slot.ja_label_from_filename("miyamai_news_20260714_morning.mp3")).to eq("朝")
      expect(Slot.ja_label_from_filename("miyamai_news_20260714_afternoon.mp3")).to eq("昼")
      expect(Slot.ja_label_from_filename("miyamai_news_20260714_evening.mp3")).to eq("夜")
      expect(Slot.ja_label_from_filename("miyamai_news_20260714_midnight.mp3")).to eq("深夜")
    end

    it "returns an empty string for a legacy filename without a slot suffix" do
      expect(Slot.ja_label_from_filename("miyamai_news_20260714.mp3")).to eq("")
    end

    it "returns an empty string when the slot suffix is not at the very end" do
      expect(Slot.ja_label_from_filename("miyamai_news_morning_extra.mp3")).to eq("")
    end
  end

  describe ".sort_key" do
    it "orders slots chronologically within a day" do
      keys = %w[morning afternoon evening midnight].map { |s| Slot.sort_key(s) }
      expect(keys).to eq(keys.sort)
      expect(Slot.sort_key("morning")).to be < Slot.sort_key("midnight")
    end

    it "raises for an unknown slot" do
      expect { Slot.sort_key("noon") }.to raise_error(KeyError)
    end

    # (date_tag, sort_key) でエピソードを時系列順に並べられることの確認。
    it "sorts episodes by (date_tag, slot) newest first" do
      episodes = [
        %w[20260720 morning],
        %w[20260719 midnight],
        %w[20260720 midnight],
        %w[20260720 afternoon]
      ]
      newest_first = episodes.sort_by { |date_tag, slot| [date_tag, Slot.sort_key(slot)] }.reverse

      expect(newest_first).to eq([
        %w[20260720 midnight],
        %w[20260720 afternoon],
        %w[20260720 morning],
        %w[20260719 midnight]
      ])
    end
  end
end
