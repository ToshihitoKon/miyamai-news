# frozen_string_literal: true

require "spec_helper"
require "internal/command_error"

RSpec.describe Internal::CommandError do
  describe ".tail" do
    it "returns the string as-is when shorter than max_chars" do
      expect(described_class.tail("short error")).to eq("short error")
    end

    it "returns the last max_chars characters when longer than max_chars" do
      err = "a" * 400
      expect(described_class.tail(err, max_chars: 300)).to eq("a" * 300)
    end

    it "returns the string as-is when exactly max_chars long" do
      err = "a" * 300
      expect(described_class.tail(err, max_chars: 300)).to eq(err)
    end
  end
end
