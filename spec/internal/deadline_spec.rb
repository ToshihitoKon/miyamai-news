# frozen_string_literal: true

require "spec_helper"
require "internal/deadline"

RSpec.describe Internal::Deadline do
  before do
    @clock = 100.0
    allow(described_class).to receive(:now) { @clock }
  end

  describe ".in" do
    it "sets the deadline the given seconds after now" do
      deadline = described_class.in(300)

      expect(deadline.remaining_sec).to eq(300)
    end
  end

  describe "#remaining_sec" do
    it "shrinks as the clock advances and goes negative after the deadline" do
      deadline = described_class.in(10)

      @clock += 4
      expect(deadline.remaining_sec).to eq(6)

      @clock += 10
      expect(deadline.remaining_sec).to eq(-4)
    end
  end
end
