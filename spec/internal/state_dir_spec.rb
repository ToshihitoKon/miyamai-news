# frozen_string_literal: true

require "spec_helper"
require "internal/state_dir"

RSpec.describe StateDir do
  it "is work/state" do
    expect(described_class.path("/work")).to eq(File.join("/work", "state"))
  end
end
