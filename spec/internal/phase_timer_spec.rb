# frozen_string_literal: true

require "spec_helper"
require "internal/phase_timer"

RSpec.describe Internal::PhaseTimer do
  let(:timer) { described_class.new }

  def captured_warnings
    messages = []
    allow(timer).to receive(:warn) { |msg| messages << msg }
    yield
    messages
  end

  describe "#measure" do
    it "ブロックの戻り値をそのまま返す" do
      result = timer.measure("digest") { 42 }

      expect(result).to eq(42)
    end
  end

  describe "#report" do
    it "measure した値を見出し行+インデント行で出力する" do
      messages = captured_warnings do
        timer.measure("digest") {}
        timer.measure("writer") {}
        timer.report
      end

      expect(messages.first).to eq("phase duration:")
      expect(messages[1..]).to all(match(/\A  \w+: [\d.]+s\z/))
      expect(messages[1..].map { |l| l[/\A  (\w+):/, 1] }).to eq(%w[digest writer])
    end

    it "measure ブロック内で例外が発生したフェーズにだけ (failed) が付く" do
      messages = captured_warnings do
        timer.measure("digest") {}
        expect { timer.measure("writer") { raise "boom" } }.to raise_error(RuntimeError)
        timer.report
      end

      expect(messages[1]).to match(/\A  digest: [\d.]+s\z/)
      expect(messages[2]).to match(/\A  writer: [\d.]+s \(failed\)\z/)
    end

    it "measure ブロック内で abort（SystemExit）したフェーズにも (failed) が付く" do
      messages = captured_warnings do
        expect { timer.measure("publish") { abort "x" } }.to raise_error(SystemExit)
        timer.report
      end

      expect(messages[1]).to match(/\A  publish: [\d.]+s \(failed\)\z/)
    end

    it "一度も measure されていない場合、見出し行を含め何も出力しない" do
      messages = captured_warnings { timer.report }

      expect(messages).to be_empty
    end
  end
end
