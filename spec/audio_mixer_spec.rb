# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "audio_mixer"

RSpec.describe AudioMixer do
  let(:work_dir) { Dir.mktmpdir }
  let(:bgm_path) { File.join(work_dir, "bgm.mp3") }
  let(:voice_path) { File.join(work_dir, "voice.mp3") }
  let(:output_path) { File.join(work_dir, "output.mp3") }
  let(:success_status) { instance_double(Process::Status, success?: true) }

  before do
    File.write(bgm_path, "fake bgm")
    File.write(voice_path, "fake voice")
  end

  after { FileUtils.remove_entry(work_dir) }

  describe "#mix" do
    it "mixes voice and bgm by shelling out to ffprobe/ffmpeg" do
      allow(Open3).to receive(:capture3) do |*cmd|
        cmd.first == "ffprobe" ? ["12.5\n", "", success_status] : ["", "", success_status]
      end

      mixer = described_class.new(bgm_path: bgm_path)
      result = mixer.mix(voice_path, output_path)

      expect(result).to eq(output_path)
      expect(Open3).to have_received(:capture3).with(
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", voice_path
      )

      fade_start = described_class::INTRO_SEC + 12.5 + described_class::TAIL_SEC
      total_dur = fade_start + described_class::FADE_SEC
      expect(Open3).to have_received(:capture3).with(
        "ffmpeg", "-y",
        "-stream_loop", "-1", "-i", bgm_path,
        "-i", voice_path,
        "-filter_complex", a_string_matching(/amix=inputs=2/),
        "-map", "[out]", "-t", total_dur.to_s,
        "-c:a", "libmp3lame", "-q:a", "4", output_path
      )
    end

    it "raises when ffprobe fails" do
      failure_status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(["", "probe failed", failure_status])

      mixer = described_class.new(bgm_path: bgm_path)
      expect { mixer.mix(voice_path, output_path) }.to raise_error(/ffprobe failed/)
    end

    it "raises when ffmpeg mix fails" do
      allow(Open3).to receive(:capture3) do |*cmd|
        if cmd.first == "ffprobe"
          ["12.5\n", "", success_status]
        else
          ["", "mix failed", instance_double(Process::Status, success?: false)]
        end
      end

      mixer = described_class.new(bgm_path: bgm_path)
      expect { mixer.mix(voice_path, output_path) }.to raise_error(/ffmpeg mix failed/)
    end

    it "aborts when the bgm file is missing" do
      mixer = described_class.new(bgm_path: File.join(work_dir, "missing.mp3"))
      expect { mixer.mix(voice_path, output_path) }.to raise_error(SystemExit)
    end
  end
end
