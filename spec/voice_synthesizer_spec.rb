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
end
