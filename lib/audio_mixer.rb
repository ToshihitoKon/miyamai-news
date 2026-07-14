# frozen_string_literal: true

require "open3"
require_relative "internal/config"

class AudioMixer
  class << self
    def bgm_volume = @bgm_volume ||= Config.get("mixer.bgm_volume").to_f
    def intro_sec = @intro_sec ||= Config.get("mixer.intro_sec").to_f   # BGM 開始からナレーション開始まで
    def tail_sec = @tail_sec ||= Config.get("mixer.tail_sec").to_f     # ナレーション終了からフェードアウト開始まで
    def fade_sec = @fade_sec ||= Config.get("mixer.fade_sec").to_f     # フェードアウトにかける秒数
  end

  def initialize(bgm_path:)
    @bgm_path = bgm_path
  end

  # ナレーション mp3 に BGM を当てて output_path に書き出す。
  def mix(voice_path, output_path)
    abort "BGM not found: #{@bgm_path}" unless File.exist?(@bgm_path)

    voice_dur = probe_duration(voice_path)
    fade_start = self.class.intro_sec + voice_dur + self.class.tail_sec
    total_dur = fade_start + self.class.fade_sec
    delay_ms = (self.class.intro_sec * 1000).to_i

    warn "voice: #{voice_dur.round(1)}s / bgm volume: #{self.class.bgm_volume} / total: #{total_dur.round(1)}s"

    run_mix(voice_path, output_path, fade_start: fade_start, total_dur: total_dur, delay_ms: delay_ms)
    warn "mixed: #{output_path}"
    output_path
  end

  private

  def probe_duration(path)
    out, err, status = Open3.capture3(
      "ffprobe", "-v", "error", "-show_entries", "format=duration",
      "-of", "default=noprint_wrappers=1:nokey=1", path
    )
    raise "ffprobe failed: #{err[-300..]}" unless status.success?

    out.strip.to_f
  end

  # -stream_loop -1: BGM がナレーションより短くても最後まで途切れないようループ
  # normalize=0: amix の自動音量正規化を無効化し、指定した音量バランスを保つ
  def run_mix(voice_path, output_path, fade_start:, total_dur:, delay_ms:)
    filter = "[0:a]volume=#{self.class.bgm_volume},afade=t=out:st=#{fade_start}:d=#{self.class.fade_sec}[bgm]; " \
             "[1:a]adelay=#{delay_ms}|#{delay_ms}[voice]; " \
             "[bgm][voice]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[out]"

    _out, err, status = Open3.capture3(
      "ffmpeg", "-y",
      "-stream_loop", "-1", "-i", @bgm_path,
      "-i", voice_path,
      "-filter_complex", filter,
      "-map", "[out]", "-t", total_dur.to_s,
      "-c:a", "libmp3lame", "-q:a", "4", output_path
    )
    raise "ffmpeg mix failed: #{err[-300..]}" unless status.success?
  end
end
