# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require_relative "../../../scripts/lib/tts_reading_check/transcript"
require_relative "../../../scripts/lib/tts_reading_check/prompt"

RSpec.describe TtsReadingCheck::Transcript do
  describe ".parse" do
    it "ignores preamble lines and accepts full-width colons" do
      output = "書き起こしました。\n1: そらの\n2：じっぷん\n"
      expect(described_class.parse(output, 2)).to eq(%w[そらの じっぷん])
    end

    {
      "full-width digits and colon" => "１：あ\n２：い\n",
      "a period separator" => "1. あ\n2. い\n",
      "a full-width period separator" => "１．あ\n２．い\n",
      "hyphen list markers" => "- 1: あ\n- 2: い\n",
      "asterisk list markers" => "* 1: あ\n* 2: い\n",
      "middle dot list markers" => "・1：あ\n・2：い\n",
      "bold numbers" => "**1**: あ\n**2**: い\n",
      "bold numbers with the colon inside" => "**1:** あ\n**2:** い\n",
      "list markers with bold numbers" => "- **1**: あ\n- **2**: い\n",
      "no space after the separator" => "1:あ\n2:い\n",
      "leading indentation" => "  1: あ\n  2: い\n"
    }.each do |form, output|
      it "accepts #{form}" do
        expect(described_class.parse(output, 2)).to eq(%w[あ い])
      end
    end

    it "keeps ignoring preamble lines that only look list-like" do
      output = "次の通りです\n- 書き起こし結果\n**結果**\n1: あ\n2: い\n"
      expect(described_class.parse(output, 2)).to eq(%w[あ い])
    end

    it "keeps an empty line as an empty transcription" do
      expect(described_class.parse("1: あ\n2:\n", 2)).to eq(["あ", ""])
    end

    it "raises with the missing numbers when a chunk is absent" do
      expect { described_class.parse("1: あ\n3: う\n", 3) }
        .to raise_error(described_class::Error, /2/)
    end

    it "raises with the start of the output when no line is numbered, as when a safety filter blocked the request" do
      output = "This request was blocked by Gemini's filters.\n#{'x' * 300}"
      expect { described_class.parse(output, 2) }
        .to raise_error(described_class::Error, /\Atranscript has no numbered lines: This request was blocked by Gemini's filters\. x+…\z/)
      expect { described_class.parse(" \n", 2) }.to raise_error(described_class::Error, /no numbered lines: \(empty output\)/)
    end

    it "ignores numbered preamble lines outside 1..expected_count before the list starts" do
      output = "0: ぜろ\n1: あ\n2: い\n"
      expect(described_class.parse(output, 2)).to eq(%w[あ い])
    end

    it "raises when a number beyond expected_count appears inside the list, as when one chunk was split in two" do
      output = "1: あ\n2: いの\n3: つづき\n"
      expect { described_class.parse(output, 2) }
        .to raise_error(described_class::Error, /unexpected lines after the first numbered line: 3: つづき/)
    end

    it "raises when an unnumbered line appears inside the list, as when a transcription wrapped" do
      expect { described_class.parse("1: あいう\nえお\n2: い\n", 2) }
        .to raise_error(described_class::Error, /unexpected lines after the first numbered line: えお/)
    end

    it "reads a hand-fixed output saved with a UTF-8 BOM" do
      expect(described_class.parse("\uFEFF1: あ\n2: い\n", 2)).to eq(%w[あ い])
    end

    it "raises instead of crashing when a hand-fixed output is not valid UTF-8" do
      output = "1: あ\n2: い\n".encode("Shift_JIS").force_encoding("UTF-8")
      expect { described_class.parse(output, 2) }.to raise_error(described_class::Error, /not valid UTF-8/)
    end

    it "ignores blank lines and code fences inside the list" do
      expect(described_class.parse("```\n1: あ\n\n2: い\n```\n", 2)).to eq(%w[あ い])
    end

    it "orders lines by number regardless of output order" do
      expect(described_class.parse("2: い\n1: あ\n", 2)).to eq(%w[あ い])
    end

    it "raises with the duplicated numbers instead of letting a later line win" do
      output = "1: あ\n2: い\n1. ぜんぶかきおこしました\n"
      expect { described_class.parse(output, 2) }
        .to raise_error(described_class::Error, /duplicate line numbers: 1\z/)
    end
  end

  describe ".save_raw and .load_raw_matching" do
    let(:dir) { Dir.mktmpdir }
    let(:output_path) { File.join(dir, "t.transcribe.txt") }
    let(:inputs_path) { File.join(dir, "t.transcribe.inputs.txt") }

    after { FileUtils.remove_entry(dir) }

    it "returns the saved raw output only when the inputs match in order" do
      described_class.save_raw(output_path, inputs_path, output: "1: あ\n2: い\n", inputs: %w[aaa bbb])
      expect(described_class.load_raw_matching(output_path, inputs_path, %w[aaa bbb])).to eq("1: あ\n2: い\n")
      expect(described_class.load_raw_matching(output_path, inputs_path, %w[bbb aaa])).to be_nil
      expect(described_class.load_raw_matching(output_path, inputs_path, %w[aaa])).to be_nil
    end

    it "writes the raw output unchanged as plain text" do
      described_class.save_raw(output_path, inputs_path, output: "1: あ\n", inputs: %w[aaa])
      expect(File.read(output_path)).to eq("1: あ\n")
    end

    it "returns nil when either file does not exist" do
      File.write(output_path, "1: あ\n")
      expect(described_class.load_raw_matching(output_path, inputs_path, %w[aaa])).to be_nil

      FileUtils.rm_f(output_path)
      File.write(inputs_path, "aaa")
      expect(described_class.load_raw_matching(output_path, inputs_path, %w[aaa])).to be_nil
    end

    it "never pairs a new output with the old inputs when saving is interrupted" do
      described_class.save_raw(output_path, inputs_path, output: "1: ふるい\n", inputs: %w[old])
      allow(File).to receive(:write).and_call_original
      allow(File).to receive(:write).with(inputs_path, anything).and_raise(Interrupt)

      expect { described_class.save_raw(output_path, inputs_path, output: "1: あたらしい\n", inputs: %w[new]) }
        .to raise_error(Interrupt)
      expect(described_class.load_raw_matching(output_path, inputs_path, %w[old])).to be_nil
    end
  end

  describe "transcribe prompt" do
    it "lists every wav path with a 1-based number and forbids other tools" do
      prompt = TtsReadingCheck::Prompt.render(TtsReadingCheck::Prompt::TRANSCRIBE, wav_paths: %w[/d/0000_a.wav /d/0001_b.wav])
      expect(prompt).to include("1: /d/0000_a.wav", "2: /d/0001_b.wav", "ひらがなだけ")
    end
  end
end
