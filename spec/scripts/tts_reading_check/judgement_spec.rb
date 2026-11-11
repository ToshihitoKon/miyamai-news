# frozen_string_literal: true

require "spec_helper"
require_relative "../../../scripts/lib/tts_reading_check/judgement"
require_relative "../../../scripts/lib/tts_reading_check/prompt"

RSpec.describe TtsReadingCheck::Judgement do
  describe ".parse" do
    it "extracts the JSON array from a fenced, chatty response" do
      output = "判定結果です。\n```json\n[{\"chunk\": 2, \"word\": \"空の\", \"expected\": \"からの\", \"heard\": \"そらの\"}]\n```\n"
      expect(described_class.parse(output, 3)).to eq(
        [described_class::Finding.new(chunk_number: 2, word: "空の", expected: "からの", heard: "そらの")]
      )
    end

    it "returns an empty list for []" do
      expect(described_class.parse("[]", 3)).to eq([])
    end

    it "raises when no JSON array is present" do
      expect { described_class.parse("問題ありません", 3) }.to raise_error(described_class::Error)
    end

    it "raises when the JSON is broken" do
      expect { described_class.parse('[{"chunk": 1,]', 3) }
        .to raise_error(described_class::Error, /no JSON array of finding objects/)
    end

    it "accepts [] as no findings only when it is the whole output, fenced or not" do
      expect(described_class.parse(" [] \n", 3)).to eq([])
      expect(described_class.parse("```json\n[]\n```\n", 3)).to eq([])
      expect(described_class.parse("```JSON\n[]\n```", 3)).to eq([])
      expect { described_class.parse("結果です。\n[]\n（注: [interval] タグは対象外）", 3) }
        .to raise_error(described_class::Error, /\[\] among other text/)
    end

    it "raises instead of reporting no findings when the real array is broken JSON" do
      nested = '[{"chunk": 1, "word": "空の", "expected": "からの", "heard": "そらの", "notes": []},]'
      expect { described_class.parse(nested, 3) }.to raise_error(described_class::Error, /\[\] among other text/)

      prose = %(疑いが無ければ [] と書きます。\n[{"chunk": 1, "word": "空の"},])
      expect { described_class.parse(prose, 3) }.to raise_error(described_class::Error, /\[\] among other text/)
    end

    it "finds the array even when the surrounding prose has brackets that are not finding arrays" do
      finding = '[{"chunk": 1, "word": "空の", "expected": "からの", "heard": "そらの"}]'
      expect(described_class.parse("[注意] 判定しました\n#{finding}", 3).map(&:word)).to eq(["空の"])
      expect(described_class.parse("[1] 件の疑いがあります\n#{finding}", 3).map(&:word)).to eq(["空の"])
    end

    it "keeps an empty array nested in a finding as part of that finding" do
      output = '[{"chunk": 1, "word": "空の", "expected": "からの", "heard": "そらの", "notes": []}]'
      expect(described_class.parse(output, 3).map(&:word)).to eq(["空の"])
    end

    it "raises instead of reporting no findings when the prose before the answer contains []" do
      output = "疑いが無ければ [] と書きますが、今回は次の通りです。\n" \
               '[{"chunk": 1, "word": "空の", "expected": "からの", "heard": "そらの"}]'
      expect { described_class.parse(output, 3) }
        .to raise_error(described_class::Error, /2 separate JSON arrays/)
    end

    it "accepts null or missing word, expected and heard as empty, as for a dropped or extra word" do
      output = '[{"chunk": 1, "word": "空の", "expected": "からの", "heard": null}, {"chunk": 2, "heard": "えっと"}]'
      expect(described_class.parse(output, 3)).to eq(
        [
          described_class::Finding.new(chunk_number: 1, word: "空の", expected: "からの", heard: ""),
          described_class::Finding.new(chunk_number: 2, word: "", expected: "", heard: "えっと")
        ]
      )
    end

    it "reads whether a finding is more likely a transcription error, with the reason" do
      output = '[{"chunk": 1, "word": "宮舞", "expected": "みやまい", "heard": "みゃまい", ' \
               '"cause": "transcription", "reason": "拗音との取り違え"}]'
      finding = described_class.parse(output, 3).first
      expect(finding).to be_transcription
      expect(finding.reason).to eq("拗音との取り違え")
    end

    it "treats a finding without a known cause as a misreading" do
      output = '[{"chunk": 1, "word": "a", "expected": "b", "heard": "c"}, ' \
               '{"chunk": 2, "word": "a", "expected": "b", "heard": "c", "cause": "unsure"}]'
      expect(described_class.parse(output, 3).map(&:cause)).to eq([described_class::MISREADING] * 2)
    end

    it "raises when an element has no chunk number" do
      output = '[{"word": "a", "expected": "b", "heard": "c"}]'
      expect { described_class.parse(output, 3) }.to raise_error(described_class::Error, /chunk/)
    end

    it "accepts a chunk number written as a digit string" do
      output = '[{"chunk": "2", "word": "a", "expected": "b", "heard": "c"}]'
      expect(described_class.parse(output, 3).map(&:chunk_number)).to eq([2])
    end

    it "raises instead of crashing when the output is not valid UTF-8" do
      output = "[{\"chunk\": 1, \"word\": \"\xff\"}]".dup.force_encoding("UTF-8")
      expect { described_class.parse(output, 3) }.to raise_error(described_class::Error, /not valid UTF-8/)
    end

    it "raises when the only array holds something other than objects" do
      expect { described_class.parse("[1]", 3) }
        .to raise_error(described_class::Error, /no JSON array of finding objects/)
    end

    it "raises when a chunk number is out of range" do
      output = '[{"chunk": 9, "word": "a", "expected": "b", "heard": "c"}]'
      expect { described_class.parse(output, 3) }.to raise_error(described_class::Error)
    end

    it "raises when a chunk number is below 1" do
      output = '[{"chunk": 0, "word": "a", "expected": "b", "heard": "c"}]'
      expect { described_class.parse(output, 3) }.to raise_error(described_class::Error)
    end
  end

  describe "judge prompt" do
    let(:prompt) do
      TtsReadingCheck::Prompt.render(TtsReadingCheck::Prompt::JUDGE, pairs: [{ number: 1, text: "空のフォルダ。", heard: "そらのふぉるだ" }])
    end

    it "embeds each numbered pair of script text and transcription" do
      expect(prompt).to include("空のフォルダ。", "そらのふぉるだ", '"chunk"')
    end

    it "forbids using tools" do
      expect(prompt).to include("ツールは一切使わない")
    end

    it "asks for empty strings instead of null for a dropped or extra word" do
      expect(prompt).to include('空文字 `""`', "null は使わない")
    end

    it "asks whether each finding is a misreading or a transcription error, defaulting to a misreading" do
      expect(prompt).to include('"cause"', '"misreading"', '"transcription"', '"reason"', '迷ったら `"misreading"`')
    end
  end
end
