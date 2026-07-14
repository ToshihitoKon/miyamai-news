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

  it "retries a failed chunk with backoff and eventually raises after MAX_RETRIES" do
    failure_status = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:popen3) do |*_cmd|
      [StringIO.new, StringIO.new, StringIO.new("synthesis error"), fake_wait_thr(failure_status)]
    end

    synth = described_class.new(work_dir: work_dir, episode: episode)

    expect { synth.synthesize(script_path) }.to raise_error(/VOICEPEAK synthesis failed/)
    expect(Open3).to have_received(:popen3).exactly(described_class::MAX_RETRIES + 1).times
  end

  it "aborts when VOICEPEAK is not executable" do
    allow(File).to receive(:executable?).and_return(false)

    synth = described_class.new(work_dir: work_dir, episode: episode)
    expect { synth.synthesize(script_path) }.to raise_error(SystemExit)
  end
end
