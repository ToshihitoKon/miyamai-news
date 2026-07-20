# frozen_string_literal: true

require "spec_helper"
require "internal/used_news_formatter"

RSpec.describe UsedNewsFormatter do
  # 正しい新フォーマットの used_news。
  let(:valid_used) do
    "## 生成AI\n### [Title A](https://example.com/a)\n   要約です。\n   (2026-07-14 / SourceA)\n"
  end
  # ## 見出しが無くパースできない used_news（旧フォーマット）。
  let(:broken_used) do
    "・Title A\n   要約です。\n   https://example.com/a\n   (2026-07-14 / SourceA)\n"
  end

  describe ".ensure_valid!" do
    it "returns the text unchanged when the format is already valid" do
      expect(Internal::AiCli).not_to receive(:run)

      expect(described_class.ensure_valid!(valid_used)).to eq(valid_used)
    end

    it "strips a preamble before the first ## heading" do
      preamble = "整形しました。\n#{valid_used}"

      expect(described_class.ensure_valid!(preamble)).to eq(valid_used)
    end

    it "returns an empty string without calling the AI when the input is blank" do
      expect(Internal::AiCli).not_to receive(:run)

      expect(described_class.ensure_valid!("")).to eq("")
      expect(described_class.ensure_valid!("   \n")).to eq("")
    end

    it "repairs a broken format via the lightweight model" do
      allow(described_class).to receive(:run_fix_cli).and_return(valid_used)

      result = described_class.ensure_valid!(broken_used)

      expect(described_class).to have_received(:run_fix_cli)
      expect(result).to eq(valid_used)
    end

    it "aborts when repair fails" do
      allow(described_class).to receive(:run_fix_cli).and_return(nil)

      expect { described_class.ensure_valid!(broken_used) }.to raise_error(SystemExit)
    end

    it "rejects a repair that invents a URL not in the input (hallucination guard) and aborts" do
      fabricated = "## 生成AI\n### [Title A](https://evil.example.com/fake)\n   要約です。\n   (2026-07-14 / SourceA)\n"
      allow(described_class).to receive(:run_fix_cli).and_return(fabricated)

      expect { described_class.ensure_valid!(broken_used) }.to raise_error(SystemExit)
    end

    it "does not call the AI at all when used_fix_max_retries is 0 (disabled)" do
      allow(Config.ai_agent).to receive(:used_fix_max_retries).and_return(0)
      expect(described_class).not_to receive(:run_fix_cli)

      expect { described_class.ensure_valid!(broken_used) }.to raise_error(SystemExit)
    end
  end

  describe ".run_fix_cli (tmp file integration)" do
    it "writes the prompt with a tmp output_path and reads back what the AI wrote there" do
      allow(Internal::AiCli).to receive(:run) do |_msg, prompt, *_args, **_kwargs|
        path = prompt[/`(.+fixed\.txt)`/, 1]
        File.write(path, "#{valid_used}\n")
        nil
      end

      result = described_class.send(:run_fix_cli, broken_used)

      expect(Internal::AiCli).to have_received(:run).with(
        "repairing used news format", an_instance_of(String), "--allowedTools", "Write",
        hash_including(fatal: false)
      )
      expect(result).to eq(valid_used.strip)
    end

    it "returns nil when the AI CLI does not write the expected file" do
      allow(Internal::AiCli).to receive(:run)

      expect(described_class.send(:run_fix_cli, broken_used)).to be_nil
    end

    it "cleans up the tmp directory after use" do
      captured_dir = nil
      allow(Internal::AiCli).to receive(:run) do |_msg, prompt, *_args, **_kwargs|
        path = prompt[/`(.+fixed\.txt)`/, 1]
        captured_dir = File.dirname(path)
        File.write(path, valid_used)
        nil
      end

      described_class.send(:run_fix_cli, broken_used)

      expect(Dir.exist?(captured_dir)).to be false
    end
  end
end
