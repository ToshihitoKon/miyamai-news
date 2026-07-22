# frozen_string_literal: true

require "open3"
require "tempfile"
require "fileutils"
require_relative "internal/config"
require_relative "internal/command_error"
require_relative "internal/episode_logger"

class VoiceSynthesizer
  NARRATOR = "Miyamai Moca"

  # VOICEPEAK の 1 回あたり合成できる文字数の上限。
  MAX_CHARS = 140

  # tts_script 中の話題転換マーカー（format.prompt.erb が挿入）。TEXT_WITH_FOLLOWING_TAG
  # は本文を「テキスト片, 直後のタグ名(無ければnil)」の組として非貪欲に繰り返し切り出す。
  INTERVAL_TAG = /\[interval:(mid|long)\]/
  TEXT_WITH_FOLLOWING_TAG = /(.*?)(?:#{INTERVAL_TAG}|\z)/m

  # work/ に作る回ごとの中間ファイル/ディレクトリの glob パターン（clean 対象のみ。
  # wav_* はチャンク wav を入れるディレクトリ）。
  def self.work_globs(work_dir)
    %w[wav_* voice_*.mp3].map { |pat| File.join(work_dir, pat) }
  end

  # @param episode [Episode] 番組コンテキスト（中間ファイル名の date_tag/slot に使う）
  def initialize(work_dir:, episode:)
    @work_dir = work_dir
    @slot = episode.slot
    @date_tag = episode.date_tag
  end

  # 台本テキストを合成し、生成した mp3 のパスを返す。既に voice_path があれば
  # VOICEPEAK を起動せず再利用する。
  def synthesize(script_path)
    if File.exist?(voice_path)
      warn "voice: #{voice_path} (skip synthesis, already exists)"
      return voice_path
    end

    abort "VOICEPEAK not found: #{voicepeak_bin}" unless File.executable?(voicepeak_bin)

    chunks = split_chunks(File.read(script_path))
    abort "empty script: #{script_path}" if chunks.empty?

    warn "narrator: #{NARRATOR} / chunks: #{chunks.size}"

    wav_dir = File.join(@work_dir, "wav_#{@date_tag}_#{@slot}")
    FileUtils.mkdir_p(wav_dir)

    wav_paths = chunks.each_with_index.map do |chunk, i|
      path = File.join(wav_dir, format("%04d.wav", i))
      # 前回クラッシュした場合に備え、合成済みの WAV が残っていれば再利用して
      # 続きから再開する（合成完了時に wav_dir ごと消えるので、残存＝未完了分）。
      if File.exist?(path)
        warn "  [#{i + 1}/#{chunks.size}] skip (already synthesized)"
        next path
      end

      warn "  [#{i + 1}/#{chunks.size}] #{chunk[:text][0, 30]}"
      synthesize_chunk(chunk[:text], path)
      sleep interval_sec
      path
    end

    concat_to_mp3(wav_paths, chunks.map { |c| c[:pause] }, voice_path)
    FileUtils.rm_rf(wav_dir)

    warn "voice: #{voice_path}"
    voice_path
  end

  private

  def voice_path = File.join(@work_dir, "voice_#{@date_tag}_#{@slot}.mp3")

  def voicepeak_bin = Config.voicepeak.bin

  # 各チャンク合成後に空ける秒数。VOICEPEAK の連続起動によるクラッシュ避け。
  def interval_sec = Config.voicepeak.interval_sec

  # 合成失敗時のリトライ回数と、指数バックオフの初期待機秒数（VOICEPEAK は
  # まれに初期化時にクラッシュするため）。
  def max_retries = Config.voicepeak.max_retries
  def retry_base_sec = Config.voicepeak.retry_base_sec

  # 1チャンクの合成に許す最大秒数。VOICEPEAK は異常終了後にハングし応答しなく
  # なることがあり、超過したら kill してリトライへ回す。
  def timeout_sec = Config.voicepeak.timeout_sec

  # チャンク結合時に挟む無音の秒数（:short=通常の文区切り / :mid=[interval:mid]
  # 個々のニュースの切り替え / :long=[interval:long] カテゴリ・トピックの転換）。
  def chunk_gap_sec = Config.voicepeak.chunk_gap_sec
  def mid_pause_sec = Config.voicepeak.mid_pause_sec
  def long_pause_sec = Config.voicepeak.long_pause_sec

  # 1チャンクを WAV に合成する。失敗時は指数バックオフで max_retries 回まで再試行する。
  def synthesize_chunk(text, out_path)
    attempt = 0
    begin
      run_voicepeak(text, out_path)
    rescue RuntimeError => e
      attempt += 1
      raise if attempt > max_retries

      wait = retry_base_sec * (2**(attempt - 1))
      warn "    synthesis failed (attempt #{attempt}/#{max_retries}): #{e.message} / retry in #{wait}s"
      Internal::EpisodeLogger.record("voicepeak_chunk", attempt: attempt, error: e.message, retry_in_sec: wait)
      sleep wait
      retry
    end
  end

  # VOICEPEAK を1回起動してWAVを生成する。timeout_sec 超過はハングとみなし
  # プロセスグループごと kill して RuntimeError を投げる（呼び出し元がリトライする）。
  def run_voicepeak(text, out_path)
    start = Internal::EpisodeLogger.start_timer

    # 新しいプロセスグループで起動し、ハング時に子孫ごとまとめて kill できるようにする。
    stdin, stdout, stderr, wait_thr = Open3.popen3(
      voicepeak_bin, "--narrator", NARRATOR, "--say", text, "--out", out_path,
      pgroup: true
    )
    stdin.close
    pgid = Process.getpgid(wait_thr.pid)

    # stdout/stderr を join 前に別スレッドで読み進める（偽ハング対策、詳細は CLAUDE.md 参照）。
    stdout_reader = Thread.new { stdout.read }
    stderr_reader = Thread.new { stderr.read }

    unless wait_thr.join(timeout_sec)
      kill_process_group(pgid)
      Internal::EpisodeLogger.record("voicepeak_chunk",
        duration_sec: Internal::EpisodeLogger.elapsed_since(start), timed_out: true)
      raise "VOICEPEAK did not respond within #{timeout_sec}s (treated as hang, killed)"
    end

    status = wait_thr.value
    out = stdout_reader.value
    err = stderr_reader.value
    Internal::EpisodeLogger.record("voicepeak_chunk", duration_sec: Internal::EpisodeLogger.elapsed_since(start),
      exit_code: status.exitstatus, stdout: out, stderr: err)

    raise "VOICEPEAK synthesis failed: #{Internal::CommandError.tail(err)}" unless status.success?
    raise "VOICEPEAK did not produce an audio file: #{out_path}" unless File.exist?(out_path)
  ensure
    stdout_reader&.kill
    stderr_reader&.kill
    stdout&.close
    stderr&.close
  end

  # プロセスグループを TERM → （残っていれば）KILL の順で終了させる。
  def kill_process_group(pgid)
    Process.kill("TERM", -pgid)
    sleep 0.5
    Process.kill("KILL", -pgid)
  rescue Errno::ESRCH
    # 既に終了済み。何もしない。
  end

  # 台本を合成単位のチャンクに分割する。戻り値は { text:, pause: } の配列。
  # INTERVAL_TAG は「。」分割・MAX_CHARS 分割より先に抜き出す（後にすると分割が
  # タグ文字列を横切って壊す恐れがあるため）。
  def split_chunks(script)
    normalized = script.gsub(/\r\n?/, "\n")

    # 末尾に空文字列＋タグなしの組が必ず1つ余分に付くため取り除く。
    text_and_pause = normalized.scan(TEXT_WITH_FOLLOWING_TAG)
      .map { |text, tag| [text, tag&.to_sym] }
    text_and_pause.pop if text_and_pause.last == ["", nil]

    chunks = []
    text_and_pause.each do |text, pause|
      sentences = text.split(/(?<=。)/) # 「。」の直後で分割（句点は各文に残す）
        .map(&:strip)
        .reject(&:empty?)
        .flat_map { |sentence| split_long_sentence(sentence) }
      # タグ直後に文が続かない場合、この pause はどのチャンクにも乗らず捨てられる
      # （低頻度の許容済みエッジケース）。
      next if sentences.empty?

      sentences.each_with_index do |sentence, i|
        is_last = i == sentences.size - 1
        chunks << { text: sentence, pause: is_last ? (pause || :short) : :short }
      end
    end
    chunks
  end

  # MAX_CHARS を超える1文を、読点（、）優先で MAX_CHARS 以内の断片に分ける。
  # 読点でも切れない場合は文字数で強制的に切る。
  def split_long_sentence(sentence)
    return [sentence] if sentence.length <= MAX_CHARS

    chunks = []
    buffer = +""
    sentence.split(/(?<=、)/).each do |part|
      if part.length > MAX_CHARS
        chunks << buffer unless buffer.empty?
        buffer = +""
        part.chars.each_slice(MAX_CHARS) { |slice| chunks << slice.join }
        next
      end

      if (buffer.length + part.length) > MAX_CHARS
        chunks << buffer
        buffer = +""
      end
      buffer << part
    end
    chunks << buffer unless buffer.empty?
    chunks
  end

  # 複数の WAV を ffmpeg の concat demuxer で1本に連結し、mp3 にエンコードする。
  # pauses は wav_paths と同じ長さの配列で、各チャンク直後の無音種類を表す
  # （末尾要素は無視。最後のチャンクの後には何も挟まない）。
  def concat_to_mp3(wav_paths, pauses, output)
    silence_files = generate_silence_set

    list = Tempfile.new(["concat", ".txt"])
    wav_paths.each_with_index do |p, i|
      list.puts("file '#{p}'")
      next if i == wav_paths.size - 1

      silence = silence_files[pauses[i]]
      list.puts("file '#{silence.path}'") if silence
    end
    list.close

    _out, err, status = Open3.capture3(
      "ffmpeg", "-y", "-f", "concat", "-safe", "0",
      "-i", list.path, "-c:a", "libmp3lame", "-q:a", "4", output
    )
    raise "ffmpeg concat failed: #{Internal::CommandError.tail(err)}" unless status.success?
  ensure
    list&.unlink
    silence_files&.each_value(&:unlink)
  end

  # :short/:mid/:long 用の無音 WAV を作る。秒数が0以下の種類はキー自体を持たない
  # （concat_to_mp3 側は Hash#[] の nil でスキップする）。
  def generate_silence_set
    { short: chunk_gap_sec, mid: mid_pause_sec, long: long_pause_sec }.filter_map do |kind, sec|
      next unless sec.positive?

      silence = Tempfile.new(["silence_#{kind}", ".wav"])
      silence.close
      generate_silence(silence.path, sec)
      [kind, silence]
    end.to_h
  end

  def generate_silence(out_path, duration_sec)
    _out, err, status = Open3.capture3(
      "ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono",
      "-t", duration_sec.to_s, out_path
    )
    raise "silence generation failed: #{Internal::CommandError.tail(err)}" unless status.success?
  end
end
