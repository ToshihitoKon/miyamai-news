# frozen_string_literal: true

require "spec_helper"
require "slot"

RSpec.describe Slot do
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
