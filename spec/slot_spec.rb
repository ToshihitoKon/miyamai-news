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
end
