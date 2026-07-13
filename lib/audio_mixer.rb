# frozen_string_literal: true

require "open3"
require_relative "internal/config"

class AudioMixer
  BGM_VOLUME = Config.get("mixer.bgm_volume").to_f
  INTRO_SEC = Config.get("mixer.intro_sec").to_f   # BGM 開始からナレーション開始まで
  TAIL_SEC = Config.get("mixer.tail_sec").to_f     # ナレーション終了からフェードアウト開始まで
  FADE_SEC = Config.get("mixer.fade_sec").to_f     # フェードアウトにかける秒数

  def initialize(bgm_path:)
    @bgm_path = bgm_path
  end

  # ナレーション mp3 に BGM を当てて output_path に書き出す。
  def mix(voice_path, output_path)
    abort "BGM が見つかりません: #{@bgm_path}" unless File.exist?(@bgm_path)

    voice_dur = probe_duration(voice_path)
    fade_start = INTRO_SEC + voice_dur + TAIL_SEC
    total_dur = fade_start + FADE_SEC
    delay_ms = (INTRO_SEC * 1000).to_i

    warn "ナレーション長: #{voice_dur.round(1)}s / BGM音量: #{BGM_VOLUME} / 全体長: #{total_dur.round(1)}s"

    run_mix(voice_path, output_path, fade_start: fade_start, total_dur: total_dur, delay_ms: delay_ms)
    warn "完成版を出力: #{output_path}"
    output_path
  end

  private

  def probe_duration(path)
    out, err, status = Open3.capture3(
      "ffprobe", "-v", "error", "-show_entries", "format=duration",
      "-of", "default=noprint_wrappers=1:nokey=1", path
    )
    raise "ffprobe に失敗しました: #{err[-300..]}" unless status.success?

    out.strip.to_f
  end

  # -stream_loop -1: BGM がナレーションより短くても最後まで途切れないようループ
  # normalize=0: amix の自動音量正規化を無効化し、指定した音量バランスを保つ
  def run_mix(voice_path, output_path, fade_start:, total_dur:, delay_ms:)
    filter = "[0:a]volume=#{BGM_VOLUME},afade=t=out:st=#{fade_start}:d=#{FADE_SEC}[bgm]; " \
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
    raise "ffmpeg での BGM 合成に失敗しました: #{err[-300..]}" unless status.success?
  end
end
