# frozen_string_literal: true

require "open3"
require_relative "internal/config"
require_relative "internal/command_error"

class AudioMixer
  def initialize(bgm_path:)
    @bgm_path = bgm_path
  end

  def mix(voice_path, output_path)
    abort "BGM not found: #{@bgm_path}" unless File.exist?(@bgm_path)

    voice_dur = probe_duration(voice_path)
    fade_start = intro_sec + voice_dur + tail_sec
    total_dur = fade_start + fade_sec
    delay_ms = (intro_sec * 1000).to_i

    warn "voice: #{voice_dur.round(1)}s / voice boost: #{voice_boost_db}dB / bgm volume: #{bgm_volume} / total: #{total_dur.round(1)}s"

    run_mix(voice_path, output_path, fade_start: fade_start, total_dur: total_dur, delay_ms: delay_ms)
    warn "mixed: #{output_path}"
    output_path
  end

  private

  def bgm_volume = Config.mixer.bgm_volume
  # VOICEPEAK の出力音量が小さめなため底上げするゲイン(dB)。未指定時は0(無調整)。
  def voice_boost_db = Config.mixer.voice_boost_db
  # ミックスのタイムライン: [intro_sec: BGM単独] → [ナレーション] →
  # [tail_sec: BGM単独] → [fade_sec: フェードアウト]
  def intro_sec = Config.mixer.intro_sec
  def tail_sec = Config.mixer.tail_sec
  def fade_sec = Config.mixer.fade_sec

  def probe_duration(path)
    out, err, status = Open3.capture3(
      "ffprobe", "-v", "error", "-show_entries", "format=duration",
      "-of", "default=noprint_wrappers=1:nokey=1", path
    )
    raise "ffprobe failed: #{Internal::CommandError.tail(err)}" unless status.success?

    out.strip.to_f
  end

  # -stream_loop -1: BGM がナレーションより短くても最後まで途切れないようループ
  # normalize=0: amix の自動音量正規化を無効化し、指定した音量バランスを保つ
  def run_mix(voice_path, output_path, fade_start:, total_dur:, delay_ms:)
    filter = "[0:a]volume=#{bgm_volume},afade=t=out:st=#{fade_start}:d=#{fade_sec}[bgm]; " \
             "[1:a]volume=#{voice_boost_db}dB,adelay=#{delay_ms}|#{delay_ms}[voice]; " \
             "[bgm][voice]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[out]"

    _out, err, status = Open3.capture3(
      "ffmpeg", "-y",
      "-stream_loop", "-1", "-i", @bgm_path,
      "-i", voice_path,
      "-filter_complex", filter,
      "-map", "[out]", "-t", total_dur.to_s,
      "-c:a", "libmp3lame", "-q:a", "4", output_path
    )
    raise "ffmpeg mix failed: #{Internal::CommandError.tail(err)}" unless status.success?
  end
end
