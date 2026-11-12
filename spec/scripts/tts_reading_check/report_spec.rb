# frozen_string_literal: true

require "spec_helper"
require_relative "../../../scripts/lib/tts_reading_check/judgement"
require_relative "../../../scripts/lib/tts_reading_check/report"

RSpec.describe TtsReadingCheck::Report do
  let(:finding) { TtsReadingCheck::Judgement::Finding.new(chunk_number: 2, word: "空の", expected: "からの", heard: "そらの") }
  let(:args) do
    { tts_script_path: File.join(Config::ROOT_DIR, "work/handoff_tts_script_20261111_morning.txt"),
      generated_at: Time.new(2026, 11, 11, 19, 30, 0, "+09:00"),
      chunk_texts: %w[挨拶。 空のフォルダ。], transcripts: %w[あいさつ そらのふぉるだ],
      wav_paths: %w[/w/0000_a.wav /w/0001_b.wav], reused_batch_count: 0, batch_count: 1 }
  end

  it "lists only chunks with findings, with expected and heard readings and the wav path" do
    md = described_class.render(**args, findings: [finding])
    expect(md).to include("work/handoff_tts_script_20261111_morning.txt", "チャンク数: 2", "1 件（1 チャンク）",
      "## チャンク 2", "空のフォルダ。", "そらのふぉるだ", "空の: 期待 からの / 聞こえた そらの", "/w/0001_b.wav")
    expect(md).not_to include("## チャンク 1")
    expect(md).not_to include("|")
  end

  it "shows the script and wav paths relative to the repo root" do
    wav_path = File.join(Config::ROOT_DIR, "work/wav_20261111_morning/0001_b.wav")
    md = described_class.render(**args, wav_paths: ["/w/0000_a.wav", wav_path], findings: [finding])
    expect(md).to include("- 対象: work/handoff_tts_script_20261111_morning.txt", "- wav: work/wav_20261111_morning/0001_b.wav")
    expect(md).not_to include(Config::ROOT_DIR)
  end

  it "renders the run time with date, minutes and utc offset" do
    expect(described_class.render(**args, findings: [])).to include("- 実行日時: 2026-11-11 19:30 +0900")
  end

  it "orders chunk sections by chunk number and groups several findings of one chunk" do
    later = TtsReadingCheck::Judgement::Finding.new(chunk_number: 2, word: "行って", expected: "いって", heard: "おこなって")
    first = TtsReadingCheck::Judgement::Finding.new(chunk_number: 1, word: "挨拶", expected: "あいさつ", heard: "あいざつ")
    md = described_class.render(**args, findings: [finding, later, first])
    expect(md).to include("3 件（2 チャンク）")
    expect(md.scan("## チャンク")).to eq(["## チャンク", "## チャンク"])
    expect(md.index("## チャンク 1")).to be < md.index("## チャンク 2")
    expect(md).to include(
      "- 疑い\n  - 空の: 期待 からの / 聞こえた そらの\n  - 行って: 期待 いって / 聞こえた おこなって\n- wav:"
    )
  end

  it "marks findings that are more likely transcription errors and counts them in the header" do
    wobble = TtsReadingCheck::Judgement::Finding.new(chunk_number: 1, word: "挨拶", expected: "あいさつ", heard: "あいざつ",
      cause: TtsReadingCheck::Judgement::TRANSCRIPTION, reason: "清音と濁音の違い")
    md = described_class.render(**args, findings: [finding, wobble])
    expect(md).to include("2 件（2 チャンク、うち書き起こしの揺れの可能性が高いもの 1 件）",
      "  - 挨拶: 期待 あいさつ / 聞こえた あいざつ（書き起こしの揺れの可能性が高い: 清音と濁音の違い）\n",
      "  - 空の: 期待 からの / 聞こえた そらの\n")

    without_reason = wobble.with(reason: "")
    expect(described_class.render(**args, findings: [without_reason]))
      .to include("聞こえた あいざつ（書き起こしの揺れの可能性が高い）\n")
  end

  it "shows an empty side of a finding as （なし）" do
    dropped = TtsReadingCheck::Judgement::Finding.new(chunk_number: 2, word: "空の", expected: "からの", heard: "")
    extra = TtsReadingCheck::Judgement::Finding.new(chunk_number: 2, word: "", expected: "", heard: "えっと")
    md = described_class.render(**args, findings: [dropped, extra])
    expect(md).to include("  - 空の: 期待 からの / 聞こえた （なし）", "  - （なし）: 期待 （なし） / 聞こえた えっと")
  end

  it "keeps a finding on one line even when a value has a newline" do
    wrapped = TtsReadingCheck::Judgement::Finding.new(chunk_number: 2, word: "空の", expected: "からの", heard: "そら\nの")
    md = described_class.render(**args, findings: [wrapped])
    expect(md).to include("  - 空の: 期待 からの / 聞こえた そら の\n- wav:")
  end

  it "says there were no findings when the list is empty" do
    md = described_class.render(**args, findings: [])
    expect(md).to include("0 件（0 チャンク）", "読み間違いの疑いはありませんでした。")
    expect(md).not_to include("## チャンク")
  end

  it "says there were no empty transcriptions when every chunk was transcribed" do
    expect(described_class.render(**args, findings: [])).to include("- 書き起こしが空のチャンク: なし")
  end

  it "lists the chunks whose transcription is blank in the header" do
    md = described_class.render(**args, transcripts: ["", "  "], findings: [finding])
    expect(md).to include("- 書き起こしが空のチャンク: 1, 2")
  end

  it "does not claim there were no findings when some transcriptions are blank" do
    md = described_class.render(**args, transcripts: ["あいさつ", ""], findings: [])
    expect(md).to include("- 書き起こしが空のチャンク: 2", "判定できていません")
    expect(md).not_to include("読み間違いの疑いはありませんでした。")
  end

  it "states whether the transcription was reused" do
    expect(described_class.render(**args, findings: [], reused_batch_count: 1)).to include("保存済みのものを使い回した")
    expect(described_class.render(**args, findings: [], reused_batch_count: 2, batch_count: 5))
      .to include("5 回に分けたうち 2 回分は保存済みのものを使い回した")
  end
end
