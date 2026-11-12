# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "digest"
require_relative "../../scripts/lib/tts_reading_check"
require "pipeline"

RSpec.describe TtsReadingCheck do
  let(:work_dir) { Dir.mktmpdir }
  let(:tts_script_path) { File.join(work_dir, "handoff_tts_script_20261111_morning.txt") }
  let(:report_path) { File.join(work_dir, "tts_report.md") }
  let(:wav_dir) { File.join(work_dir, "tts_check_20261111_morning") }
  let(:transcription_output) { "1: そらのふぉるだ\n2: じゅうぶんです" }
  let(:judge_output) { '[{"chunk":1,"word":"空の","expected":"からの","heard":"そらの"}]' }
  let(:agy_prompts) { { transcription: [], judgement: [] } }
  let(:raw_path) { File.join(work_dir, "tts_check_20261111_morning.transcribe.1.txt") }
  let(:inputs_path) { File.join(work_dir, "tts_check_20261111_morning.transcribe.1.inputs.txt") }

  def check(**options)
    described_class.new(tts_script_path:, work_dir:, report_path:, **options)
  end

  def transcription_calls = have_received(:run).with(anything, anything, hash_including(readable_dir: String))

  def wav_paths = Dir.glob(File.join(wav_dir, "*.wav")).sort

  before do
    File.write(tts_script_path, "空のフォルダ。十分です。")
    allow(File).to receive(:executable?).and_return(true)
    allow(Config.ai_agent).to receive(:bin).and_return("agy")

    allow_any_instance_of(VoiceSynthesizer).to receive(:synthesize_chunk) do |_synthesizer, text, path|
      File.write(path, "audio of #{text}")
    end
    allow_any_instance_of(VoiceSynthesizer).to receive(:sleep)

    allow(Internal::RestrictedAgy).to receive(:run) do |_message, prompt, readable_dir:, **|
      if readable_dir
        agy_prompts[:transcription] << prompt
        transcription_output
      else
        agy_prompts[:judgement] << prompt
        judge_output
      end
    end
  end

  after { FileUtils.remove_entry(work_dir) }

  it "writes a report with the judged finding" do
    path = check.run

    expect(path).to eq(report_path)
    expect(File.read(path)).to include("## チャンク 1", "空の: 期待 からの / 聞こえた そらの")
  end

  it "gives the transcription call read access to the wav dir only, and the judge call no tools" do
    check.run

    expect(Internal::RestrictedAgy).to have_received(:run)
      .with(anything, anything, model: Config.ai_agent.model, workdir: wav_dir, readable_dir: wav_dir)
    expect(Internal::RestrictedAgy).to have_received(:run)
      .with(anything, anything, model: Config.ai_agent.model, workdir: satisfy { |dir| dir != wav_dir }, readable_dir: nil)
  end

  it "passes only the wav paths to the transcription call, never the script text" do
    check.run

    prompt = agy_prompts[:transcription].first
    expect(prompt).to include(*Dir.glob(File.join(wav_dir, "*.wav")))
    expect(prompt).not_to include("空のフォルダ", "十分です")
  end

  it "passes the script text and the transcription to the judge call" do
    check.run

    expect(agy_prompts[:judgement].first).to include("空のフォルダ。", "そらのふぉるだ", "十分です。", "じゅうぶんです")
  end

  it "removes the judge's temporary workdir afterwards" do
    judge_workdir = nil
    allow(Internal::RestrictedAgy).to receive(:run) do |_message, _prompt, workdir:, readable_dir:, **|
      next transcription_output if readable_dir

      judge_workdir = workdir
      judge_output
    end

    check.run

    expect(File.exist?(judge_workdir)).to be(false)
  end

  it "removes everything but this run's wavs from the wav dir" do
    FileUtils.mkdir_p(File.join(wav_dir, "notes"))
    File.write(File.join(wav_dir, "0005_deadbeef.wav"), "old")
    File.write(File.join(wav_dir, ".DS_Store"), "x")
    File.write(File.join(wav_dir, "script.txt"), "空のフォルダ。十分です。")

    check.run

    entries = Dir.children(wav_dir)
    expect(entries.size).to eq(2)
    expect(entries).to all(match(/\A\d{4}_\h{8}\.wav\z/))
  end

  it "saves the transcription and the judge output outside the wav dir" do
    check.run

    expect(File.read(raw_path)).to eq(transcription_output)
    expect(File.read(File.join(work_dir, "tts_check_20261111_morning.judge.txt"))).to eq(judge_output)
  end

  it "reuses the saved transcription on rerun unless retranscribe is given" do
    check.run
    check.run
    expect(Internal::RestrictedAgy).to transcription_calls.once

    check(retranscribe: true).run
    expect(Internal::RestrictedAgy).to transcription_calls.twice
  end

  it "keeps the saved wavs with retranscribe and synthesizes them again only with resynthesize" do
    check.run
    stale_wav = wav_paths.first
    File.write(stale_wav, "synthesized before a VOICEPEAK dictionary change")

    check(retranscribe: true).run
    expect(File.read(stale_wav)).to eq("synthesized before a VOICEPEAK dictionary change")

    check(resynthesize: true).run
    expect(File.read(stale_wav)).to eq("audio of 空のフォルダ。")
  end

  it "transcribes again when a wav changed although its name did not" do
    check.run
    File.write(wav_paths.first, "synthesized again after a VOICEPEAK dictionary change")

    check.run

    expect(Internal::RestrictedAgy).to transcription_calls.twice
  end

  it "reuses the saved transcription after resynthesize when the audio is byte-identical" do
    check.run
    check(resynthesize: true).run

    expect(Internal::RestrictedAgy).to transcription_calls.once
  end

  it "keeps the saved wavs and transcription when a resynthesize run stops in a pre-check" do
    check.run
    saved = wav_paths.to_h { |path| [path, File.read(path)] }

    allow(Config.ai_agent).to receive(:bin).and_return("claude")
    expect { check(resynthesize: true).run }.to raise_error(SystemExit)
    allow(Config.ai_agent).to receive(:bin).and_return("agy")
    File.write(tts_script_path, "[interval:mid]")
    expect { check(resynthesize: true).run }.to raise_error(SystemExit)

    expect(wav_paths.to_h { |path| [path, File.read(path)] }).to eq(saved)
    expect(File.read(raw_path)).to eq(transcription_output)
  end

  it "shows a chunk that spans lines on one line in the report and the judge prompt" do
    File.write(tts_script_path, "最初の話題\n空のフォルダ。十分です。")

    md = File.read(check.run)

    expect(md).to include("- 本文: 最初の話題 空のフォルダ。")
    expect(agy_prompts[:judgement].first).to include("台本: 最初の話題 空のフォルダ。")
  end

  it "logs the run to a file outside the wav dir that the clean globs cover" do
    allow(Internal::EpisodeLogger).to receive(:configure).and_call_original

    check.run

    log_path = File.join(work_dir, "tts_check_20261111_morning.log")
    expect(Internal::EpisodeLogger).to have_received(:configure).with(log_path)
    expect(File.fnmatch(File.join(work_dir, Pipeline::TTS_CHECK_WORK_GLOB), log_path)).to be(true)
  end

  it "does not transcribe again when only the judgement failed" do
    allow(Internal::RestrictedAgy).to receive(:run) do |_message, _prompt, readable_dir:, **|
      next transcription_output if readable_dir

      raise Internal::RestrictedAgy::Error, "agy failed (exit 1)"
    end
    saved_glob = File.join(work_dir, "tts_check_20261111_morning.transcribe.*.txt")
    expect { check.run }.to raise_error(SystemExit, /judgement failed.*#{Regexp.escape(saved_glob)}/)

    allow(Internal::RestrictedAgy).to receive(:run) do |_message, _prompt, readable_dir:, **|
      readable_dir ? transcription_output : judge_output
    end
    check.run

    expect(Internal::RestrictedAgy).to transcription_calls.once
  end

  it "keeps the previous transcription when a retranscription replaces it with something unusable" do
    previous_path = File.join(work_dir, "tts_check_20261111_morning.transcribe.1.previous.txt")
    previous_inputs_path = File.join(work_dir, "tts_check_20261111_morning.transcribe.1.previous.inputs.txt")
    transcription_outputs = [transcription_output, *["音声ファイルを読み込めませんでした"] * 2]
    allow(Internal::RestrictedAgy).to receive(:run) do |_message, _prompt, readable_dir:, **|
      readable_dir ? transcription_outputs.shift : judge_output
    end
    check.run

    expect { check(retranscribe: true).run }.to raise_error(SystemExit, /kept in #{Regexp.escape(previous_path)}/)
    expect(File.read(previous_path)).to eq(transcription_output)

    FileUtils.mv(previous_path, raw_path)
    FileUtils.mv(previous_inputs_path, inputs_path)
    check.run
    expect(Internal::RestrictedAgy).to transcription_calls.thrice
  end

  it "does not let a second unusable retranscription push the usable one out of previous" do
    previous_path = File.join(work_dir, "tts_check_20261111_morning.transcribe.1.previous.txt")
    transcription_outputs = [transcription_output, *["読み込めませんでした"] * 2, *["やはり読み込めませんでした"] * 2]
    allow(Internal::RestrictedAgy).to receive(:run) do |_message, _prompt, readable_dir:, **|
      readable_dir ? transcription_outputs.shift : judge_output
    end
    check.run
    expect { check(retranscribe: true).run }.to raise_error(SystemExit)

    expect { check(retranscribe: true).run }.to raise_error(SystemExit) do |error|
      expect(error.message).not_to include("kept in")
    end
    expect(File.read(previous_path)).to eq(transcription_output)
    expect(File.read(raw_path)).to eq("やはり読み込めませんでした")
  end

  it "does not point to a previous transcription left by an unrelated earlier run" do
    File.write(File.join(work_dir, "tts_check_20261111_morning.transcribe.1.previous.txt"), "1: ふるい\n2: もの")
    allow(Internal::RestrictedAgy).to receive(:run) do |_message, _prompt, readable_dir:, **|
      readable_dir ? "読み込めませんでした" : judge_output
    end

    expect { check.run }.to raise_error(SystemExit) do |error|
      expect(error.message).not_to include("kept in")
    end
  end

  it "uses the hand-fixed raw output after a retranscription that did not parse" do
    transcription_outputs = ["1: そらのふぉるだ\n2: じゅうぶんです", *["1: こわれた"] * 2]
    allow(Internal::RestrictedAgy).to receive(:run) do |_message, prompt, readable_dir:, **|
      next transcription_outputs.shift if readable_dir

      agy_prompts[:judgement] << prompt
      "[]"
    end
    check.run
    expect { check(retranscribe: true).run }.to raise_error(SystemExit, /transcription output is unusable/)

    File.write(raw_path, "1: なおした\n2: じゅうぶんです")
    check.run

    expect(Internal::RestrictedAgy).to transcription_calls.thrice
    expect(agy_prompts[:judgement].last).to include("なおした")
  end

  it "aborts before synthesis when the work dir path cannot be written in the agy allow rule" do
    spaced_work_dir = File.join(work_dir, "my work")
    FileUtils.mkdir_p(spaced_work_dir)

    expect { described_class.new(tts_script_path:, work_dir: spaced_work_dir, report_path:).run }
      .to raise_error(SystemExit, %r{only A-Z a-z 0-9 _ \. / - .*: .*/my work/tts_check_20261111_morning})
    expect(Dir.exist?(File.join(spaced_work_dir, "tts_check_20261111_morning"))).to be(false)
    expect(Internal::RestrictedAgy).not_to have_received(:run)
  end

  it "aborts before synthesis when ai_agent.bin is not agy" do
    allow(Config.ai_agent).to receive(:bin).and_return("claude")

    expect { check.run }.to raise_error(SystemExit, /ai_agent.bin must be agy: claude/)
    expect(Dir.exist?(wav_dir)).to be(false)
    expect(Internal::RestrictedAgy).not_to have_received(:run)
  end

  it "transcribes again when the script was rewritten since the saved transcription" do
    check.run
    File.write(tts_script_path, "空のフォルダ。十分です。確認します。")
    allow(Internal::RestrictedAgy).to receive(:run).and_return("1: a\n2: b\n3: c", "[]")

    check.run

    expect(Internal::RestrictedAgy).to transcription_calls.twice
  end

  it "names the wav dir after the file name when the script is not a handoff file" do
    other_path = File.join(work_dir, "other_script.txt")
    File.write(other_path, "空のフォルダ。十分です。")

    described_class.new(tts_script_path: other_path, work_dir:, report_path:).run

    expect(Dir.exist?(File.join(work_dir, "tts_check_other_script"))).to be(true)
  end

  it "aborts without calling agy when the script has only interval tags" do
    File.write(tts_script_path, "[interval:mid][interval:long]")

    expect { check.run }.to raise_error(SystemExit)
    expect(Internal::RestrictedAgy).not_to have_received(:run)
  end

  it "removes a report left by an earlier run when the run aborts" do
    File.write(report_path, "previous report")
    File.write(tts_script_path, "[interval:mid]")

    expect { check.run }.to raise_error(SystemExit)
    expect(File.exist?(report_path)).to be(false)
  end

  it "runs with a key that is not a valid date" do
    invalid_date_path = File.join(work_dir, "handoff_tts_script_20261399_morning.txt")
    File.write(invalid_date_path, "空のフォルダ。十分です。")

    described_class.new(tts_script_path: invalid_date_path, work_dir:, report_path:).run

    expect(Dir.exist?(File.join(work_dir, "tts_check_20261399_morning"))).to be(true)
  end

  it "aborts without calling agy when the VOICEPEAK binary is not executable" do
    allow(File).to receive(:executable?).and_return(false)

    expect { check.run }.to raise_error(SystemExit, /VOICEPEAK not found/)
    expect(Internal::RestrictedAgy).not_to have_received(:run)
  end

  context "when a chunk's transcription line is empty and the judge reports nothing" do
    let(:transcription_output) { "1: そらのふぉるだ\n2:" }
    let(:judge_output) { "[]" }

    it "still surfaces the empty chunk in the report" do
      md = File.read(check.run)

      expect(md).to include("- 書き起こしが空のチャンク: 2")
      expect(md).not_to include("読み間違いの疑いはありませんでした。")
    end
  end

  context "when the judge output is unparsable" do
    let(:judge_output) { "問題ありません" }

    it "aborts naming the saved raw output and writes no report" do
      judge_path = File.join(work_dir, "tts_check_20261111_morning.judge.txt")

      expect { check.run }.to raise_error(SystemExit, /#{Regexp.escape(judge_path)}/)
      expect(File.read(judge_path)).to eq("問題ありません")
      expect(File.exist?(report_path)).to be(false)
    end
  end

  context "when the transcription output is unparsable" do
    let(:transcription_output) { "1: そらのふぉるだ" }

    it "aborts naming the saved raw output and writes no report" do
      expect { check.run }.to raise_error(SystemExit, /#{Regexp.escape(raw_path)}/)
      expect(File.read(raw_path)).to eq(transcription_output)
      expect(File.exist?(report_path)).to be(false)
    end

    it "saves the model, the prompt digest and the wav digests beside the raw output, outside the wav dir" do
      expect { check.run }.to raise_error(SystemExit)

      inputs = File.read(inputs_path).split("\n")
      expect(inputs[0]).to eq("model #{Config.ai_agent.model}")
      expect(inputs[1]).to match(/\Aprompt \h{64}\z/)
      expect(inputs[2..]).to eq(wav_paths.map { |path| "wav #{Digest::SHA256.file(path).hexdigest}" })
      expect(Dir.glob(File.join(work_dir, Pipeline::TTS_CHECK_WORK_GLOB))).to include(inputs_path)
    end

    it "re-parses the hand-fixed raw output on rerun without calling agy again" do
      expect { check.run }.to raise_error(SystemExit)
      File.write(raw_path, "1: そらのふぉるだ\n2: じゅうぶんです")

      md = File.read(check.run)

      expect(Internal::RestrictedAgy).to transcription_calls.twice
      expect(md).to include("使い回した")
    end

    it "transcribes once more before giving up, and names the raw output and how to recover" do
      expect { check.run }
        .to raise_error(SystemExit, /#{Regexp.escape(raw_path)} by hand and rerun, or just rerun to transcribe this batch again/)
        .and output(%r{missing line numbers: 2 \(transcribing batch 1/1 once more\)}).to_stderr

      expect(Internal::RestrictedAgy).to transcription_calls.twice
      expect(File.exist?(report_path)).to be(false)
    end

    it "transcribes the batch again on a plain rerun when the saved raw output still does not parse" do
      expect { check.run }.to raise_error(SystemExit)
      allow(Internal::RestrictedAgy).to receive(:run).and_return("1: あ\n2: い", "[]")

      expect { check.run }.to output(%r{#{Regexp.escape(raw_path)} is unusable, transcribing batch 1/1 again}).to_stderr

      expect(Internal::RestrictedAgy).to transcription_calls.thrice
      expect(File.read(raw_path)).to eq("1: あ\n2: い")
    end

    it "transcribes again with retranscribe even though the saved raw output matches" do
      expect { check.run }.to raise_error(SystemExit)
      allow(Internal::RestrictedAgy).to receive(:run).and_return("1: あ\n2: い", "[]")

      check(retranscribe: true).run

      expect(Internal::RestrictedAgy).to transcription_calls.thrice
    end

    it "does not re-parse a saved raw output left for another version of the script" do
      expect { check.run }.to raise_error(SystemExit)
      File.write(tts_script_path, "空のフォルダ。十分です。確認します。")
      allow(Internal::RestrictedAgy).to receive(:run).and_return("1: a\n2: b\n3: c", "[]")

      check.run

      expect(Internal::RestrictedAgy).to transcription_calls.thrice
    end
  end

  it "leaves only files matching the clean globs in the work dir" do
    check.run

    left_by_check = Dir.children(work_dir) - [File.basename(tts_script_path), File.basename(report_path)]
    matched_by_globs = Dir.glob(File.join(work_dir, Pipeline::TTS_CHECK_WORK_GLOB)).map { |path| File.basename(path) }
    expect(left_by_check).to match_array(matched_by_globs)
  end

  it "transcribes again when the model or the transcription prompt changed" do
    check.run

    allow(Config.ai_agent).to receive(:model).and_return("another-model")
    check.run
    expect(Internal::RestrictedAgy).to transcription_calls.twice

    template_path = TtsReadingCheck::Prompt.path(TtsReadingCheck::Prompt::TRANSCRIBE)
    allow(Digest::SHA256).to receive(:file).and_call_original
    allow(Digest::SHA256).to receive(:file).with(template_path)
      .and_return(instance_double(Digest::SHA256, hexdigest: "edited-template"))
    check.run
    expect(Internal::RestrictedAgy).to transcription_calls.thrice
  end

  it "keeps reusing the saved transcription when the work dir path changes" do
    check.run
    moved_work_dir = "#{work_dir}_moved"
    FileUtils.mv(work_dir, moved_work_dir)
    FileUtils.mkdir_p(work_dir)

    described_class.new(tts_script_path: File.join(moved_work_dir, File.basename(tts_script_path)),
      work_dir: moved_work_dir, report_path:).run

    expect(Internal::RestrictedAgy).to transcription_calls.once
  ensure
    FileUtils.rm_rf(moved_work_dir) if moved_work_dir
  end

  it "keeps the wav dir name to characters that cannot break the agy allow rule" do
    odd_path = File.join(work_dir, "handoff_tts_script_20261111_morning (1).txt")
    File.write(odd_path, "空のフォルダ。十分です。")

    described_class.new(tts_script_path: odd_path, work_dir:, report_path:).run

    expect(Internal::RestrictedAgy).to have_received(:run)
      .with(anything, anything, hash_including(readable_dir: %r{/tts_check_20261111_morning__1__\h{8}\z}))
  end

  it "aborts with the reason instead of a backtrace when VOICEPEAK keeps failing" do
    allow_any_instance_of(VoiceSynthesizer).to receive(:synthesize_chunk)
      .and_raise(VoiceSynthesizer::SynthesisError, "VOICEPEAK synthesis failed: boom")

    expect { check.run }.to raise_error(SystemExit, /synthesis failed: VOICEPEAK synthesis failed: boom \(rerun to/)
    expect(Internal::RestrictedAgy).not_to have_received(:run)
  end

  it "tells to drop --resynthesize when a resynthesize run fails partway, so the rerun keeps the new wavs" do
    allow_any_instance_of(VoiceSynthesizer).to receive(:synthesize_chunk)
      .and_raise(VoiceSynthesizer::SynthesisError, "VOICEPEAK synthesis failed: boom")

    expect { check(resynthesize: true).run }.to raise_error(SystemExit, /rerun without --resynthesize/)
  end

  it "does not hide a programming error as a synthesis failure" do
    allow_any_instance_of(VoiceSynthesizer).to receive(:synthesize_chunk).and_raise(FrozenError, "can't modify")

    expect { check.run }.to raise_error(FrozenError)
  end

  it "aborts and writes no report when agy fails" do
    allow(Internal::RestrictedAgy).to receive(:run).and_raise(Internal::RestrictedAgy::Error, "agy failed (exit 1)")

    expect { check.run }.to raise_error(SystemExit, /agy failed \(exit 1\)/)
    expect(File.exist?(report_path)).to be(false)
  end

  it "transcribes once more when the first output is unusable, as when a safety filter blocked the request" do
    transcription_outputs = ["This request was blocked by Gemini's filters.", transcription_output]
    allow(Internal::RestrictedAgy).to receive(:run) do |_message, _prompt, readable_dir:, **|
      readable_dir ? transcription_outputs.shift : judge_output
    end

    expect { check.run }.to output(/no numbered lines: This request was blocked/).to_stderr

    expect(Internal::RestrictedAgy).to transcription_calls.twice
    expect(File.read(raw_path)).to eq(transcription_output)
    expect(File.read(report_path)).to include("## チャンク 1")
  end

  context "when the chunks span more than one transcription batch" do
    let(:heard_by_text) { { "空のフォルダ。" => "そらのふぉるだ", "十分です。" => "じゅうぶんです" } }

    def batch_transcription(prompt)
      wav_path = wav_paths.find { |path| prompt.include?(path) }
      "1: #{heard_by_text.fetch(File.read(wav_path).delete_prefix('audio of '))}"
    end

    before do
      stub_const("TtsReadingCheck::TRANSCRIBE_BATCH_SIZE", 1)
      allow(Internal::RestrictedAgy).to receive(:run) do |_message, prompt, readable_dir:, **|
        if readable_dir
          agy_prompts[:transcription] << prompt
          batch_transcription(prompt)
        else
          agy_prompts[:judgement] << prompt
          judge_output
        end
      end
    end

    it "calls agy once per batch with only that batch's wavs and joins the transcriptions in order" do
      check.run

      expect(agy_prompts[:transcription].size).to eq(2)
      expect(agy_prompts[:transcription][0]).to include(wav_paths[0]).and(satisfy { |p| !p.include?(wav_paths[1]) })
      expect(agy_prompts[:transcription][1]).to include(wav_paths[1]).and(satisfy { |p| !p.include?(wav_paths[0]) })
      expect(agy_prompts[:judgement].first)
        .to match(/台本: 空のフォルダ。\n書き起こし: そらのふぉるだ.*台本: 十分です。\n書き起こし: じゅうぶんです/m)
    end

    it "transcribes again only the batch whose wav changed" do
      check.run
      File.write(wav_paths[1], "audio of 十分です。 after a VOICEPEAK dictionary change")
      heard_by_text["十分です。 after a VOICEPEAK dictionary change"] = "じゅうぶんです"

      md = File.read(check.run)

      expect(agy_prompts[:transcription].size).to eq(3)
      expect(agy_prompts[:transcription].last).to include(wav_paths[1])
      expect(md).to include("2 回に分けたうち 1 回分は保存済みのものを使い回した")
    end

    it "keeps the finished batches when a later batch fails, and transcribes only the rest on rerun" do
      allow(Internal::RestrictedAgy).to receive(:run) do |_message, prompt, readable_dir:, **|
        next judge_output unless readable_dir
        raise Internal::RestrictedAgy::Error, "agy failed (no output)" if prompt.include?(wav_paths[1])

        batch_transcription(prompt)
      end
      expect { check.run }.to raise_error(SystemExit, /the first 1 batches are saved; rerun to reuse them/)

      allow(Internal::RestrictedAgy).to receive(:run) do |_message, prompt, readable_dir:, **|
        next judge_output unless readable_dir

        agy_prompts[:transcription] << prompt
        batch_transcription(prompt)
      end
      check.run

      expect(agy_prompts[:transcription].size).to eq(1)
      expect(agy_prompts[:transcription].first).to include(wav_paths[1])
    end
  end

  describe ".latest_tts_script" do
    it "picks the newest episode by date and slot order, not by name" do
      %w[20261110_midnight 20261111_morning 20261111_evening].each do |key|
        File.write(File.join(work_dir, "handoff_tts_script_#{key}.txt"), "x")
      end

      expect(File.basename(described_class.latest_tts_script(work_dir))).to eq("handoff_tts_script_20261111_evening.txt")
    end

    it "returns nil when there is no handoff tts script" do
      FileUtils.rm_f(tts_script_path)

      expect(described_class.latest_tts_script(work_dir)).to be_nil
    end
  end
end
