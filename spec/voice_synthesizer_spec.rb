# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "episode"
require "voice_synthesizer"

RSpec.describe VoiceSynthesizer do
  let(:work_dir) { Dir.mktmpdir }
  let(:now) { Time.utc(2026, 7, 14, 12, 0, 0) } # afternoon slot
  let(:episode) { Episode.new(now: now) }
  let(:script_path) { File.join(work_dir, "script.txt") }
  let(:success_status) { instance_double(Process::Status, success?: true) }

  before do
    File.write(script_path, "こんにちは。今日のニュースです。")
    # VOICEPEAK は実機に存在しないため、実行可否チェックとプロセスグループ解決をstubする。
    allow(File).to receive(:executable?).and_return(true)
    allow(Process).to receive(:getpgid).and_return(99_999)
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  after { FileUtils.remove_entry(work_dir) }

  def fake_wait_thr(status)
    double("wait_thr", pid: 4242, join: true, value: status)
  end

  describe "#synthesize" do
    context "when voice_path already exists" do
      it "skips synthesis entirely and reuses the existing mp3" do
        existing_voice_path = File.join(work_dir, "voice_20260714_afternoon.mp3")
        File.write(existing_voice_path, "already synthesized")
        allow(Open3).to receive(:popen3)

        synth = described_class.new(work_dir: work_dir, episode: episode)
        voice_path = synth.synthesize(script_path)

        expect(voice_path).to eq(existing_voice_path)
        # before ブロックで File.executable? は true をstubしているため、実行可否チェック
        # 自体が呼ばれていないことは「VOICEPEAK起動(popen3)が発生していない」ことで確認する。
        expect(Open3).not_to have_received(:popen3)
      end
    end

    context "success" do
      it "synthesizes each chunk via VOICEPEAK and concatenates with ffmpeg, without a real binary" do
        written_wavs = []

        allow(Open3).to receive(:popen3) do |*cmd|
          out_path = cmd[cmd.index("--out") + 1]
          File.write(out_path, "fake wav")
          written_wavs << out_path
          [StringIO.new, StringIO.new, StringIO.new, fake_wait_thr(success_status)]
        end
        allow(Open3).to receive(:capture3).and_return(["", "", success_status])

        synth = described_class.new(work_dir: work_dir, episode: episode)
        voice_path = synth.synthesize(script_path)

        expect(voice_path).to eq(File.join(work_dir, "voice_20260714_afternoon.mp3"))
        expect(written_wavs).not_to be_empty
        expect(Open3).to have_received(:popen3).at_least(:once)
        expect(Open3).to have_received(:capture3).at_least(:once) # ffmpeg concat (+ silence)
      end
    end

    context "failure" do
      it "retries a failed chunk with backoff and eventually raises after max_retries" do
        failure_status = instance_double(Process::Status, success?: false)
        allow(Open3).to receive(:popen3) do |*_cmd|
          [StringIO.new, StringIO.new, StringIO.new("synthesis error"), fake_wait_thr(failure_status)]
        end

        synth = described_class.new(work_dir: work_dir, episode: episode)

        expect { synth.synthesize(script_path) }.to raise_error(/VOICEPEAK synthesis failed/)
        expect(Open3).to have_received(:popen3).exactly(synth.send(:max_retries) + 1).times
      end

      it "aborts when VOICEPEAK is not executable" do
        allow(File).to receive(:executable?).and_return(false)

        synth = described_class.new(work_dir: work_dir, episode: episode)
        expect { synth.synthesize(script_path) }.to raise_error(SystemExit)
      end
    end
  end

  describe "#split_chunks" do
    subject(:split_chunks) { described_class.new(work_dir: work_dir, episode: episode).send(:split_chunks, script) }

    context "without any interval tag" do
      let(:script) { "こんにちは。今日のニュースです。" }

      it "marks every chunk as :short" do
        expect(split_chunks).to eq(
          [
            { text: "こんにちは。", pause: :short },
            { text: "今日のニュースです。", pause: :short }
          ]
        )
      end
    end

    context "with a [interval:long] tag between sentences" do
      let(:script) { "最初のカテゴリです。[interval:long]続いてのカテゴリです。" }

      it "attaches :long to the chunk right before the tag and drops the tag text" do
        expect(split_chunks).to eq(
          [
            { text: "最初のカテゴリです。", pause: :long },
            { text: "続いてのカテゴリです。", pause: :short }
          ]
        )
      end
    end

    context "with a [interval:mid] tag between sentences" do
      let(:script) { "メインニュースです。[interval:mid]ほかにも話題がありました。" }

      it "attaches :mid to the chunk right before the tag" do
        expect(split_chunks).to eq(
          [
            { text: "メインニュースです。", pause: :mid },
            { text: "ほかにも話題がありました。", pause: :short }
          ]
        )
      end
    end

    context "when consecutive tags leave no text between them" do
      let(:script) { "最初の文です。[interval:mid][interval:long]次の文です。" }

      it "does not raise and keeps the earlier tag's pause (later tag is dropped)" do
        expect(split_chunks).to eq(
          [
            { text: "最初の文です。", pause: :mid },
            { text: "次の文です。", pause: :short }
          ]
        )
      end
    end

    context "when a sentence exceeds MAX_CHARS and is followed by a tag" do
      let(:long_sentence) { "あ" * 200 }
      let(:script) { "#{long_sentence}。[interval:long]次のカテゴリです。" }

      it "keeps :short between split fragments and puts the long pause only on the last fragment before the tag" do
        result = split_chunks

        # 最後の要素はタグの後ろの文（次のカテゴリです。）で :short。
        # それより前が、140字超の1文を分割した断片群であり、:long は最後の断片にだけ乗る。
        after_tag, fragments = result.last, result[0..-2]
        expect(fragments.size).to be > 1
        expect(fragments[0..-2].map { |c| c[:pause] }).to all(eq(:short))
        expect(fragments.last[:pause]).to eq(:long)
        expect(after_tag).to eq({ text: "次のカテゴリです。", pause: :short })

        # タグ自体はどのテキストにも残らない。
        expect(result.map { |c| c[:text] }.join).not_to include("[interval:")
      end
    end
  end

  describe "#concat_to_mp3" do
    let(:synth) { described_class.new(work_dir: work_dir, episode: episode) }
    let(:wav_paths) { %w[0000.wav 0001.wav 0002.wav] }
    let(:output) { File.join(work_dir, "voice.mp3") }
    let(:silence_durations) { [] }

    before do
      allow(Open3).to receive(:capture3) do |*cmd|
        if cmd.first == "ffmpeg" && cmd.include?("anullsrc=r=48000:cl=mono")
          silence_durations << cmd[cmd.index("-t") + 1]
        end
        ["", "", success_status]
      end
    end

    it "generates short/mid/long silence upfront regardless of which pauses actually occur" do
      synth.send(:concat_to_mp3, wav_paths, %i[short mid long], output)

      expect(silence_durations.map(&:to_f)).to contain_exactly(0.4, 1.0, 2.0)
    end

    it "writes a concat list where each wav's following silence matches its pause kind, with none after the last wav" do
      captured_lines = nil
      # concat リストは concat_to_mp3 の ensure で unlink される前提のスタブなので、
      # ffmpeg concat 呼び出し(=リスト書き込み完了直後)のタイミングで内容を読み取っておく。
      allow(Open3).to receive(:capture3) do |*cmd|
        if cmd.first == "ffmpeg" && cmd.include?("concat")
          list_path = cmd[cmd.index("-i") + 1]
          captured_lines = File.readlines(list_path).map(&:strip)
        end
        ["", "", success_status]
      end

      synth.send(:concat_to_mp3, wav_paths, %i[short mid long], output)

      # wav_paths.size 個の wav 行と、最後を除く2個分の無音行(mid, long)で計5行。
      expect(captured_lines.size).to eq(5)
      expect(captured_lines.last).to include("0002.wav")
    end
  end
end
