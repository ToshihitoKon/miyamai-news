# frozen_string_literal: true

require "open3"
require "tempfile"
require "fileutils"
require_relative "internal/config"

class VoiceSynthesizer
  class << self
    def voicepeak_bin = @voicepeak_bin ||= Config.get("voicepeak.bin")

    # 各チャンク合成後に空ける秒数。VOICEPEAK の連続起動によるクラッシュ避け。
    def interval_sec = @interval_sec ||= Config.get("voicepeak.interval_sec").to_f

    # 合成失敗時のリトライ回数と、指数バックオフの初期待機秒数。
    # VOICEPEAK はまれに初期化タイミングでクラッシュするため、待機を倍々に
    # 伸ばしながら数回やり直せば大抵は成功する。
    def max_retries = @max_retries ||= Config.get("voicepeak.max_retries").to_i
    def retry_base_sec = @retry_base_sec ||= Config.get("voicepeak.retry_base_sec").to_f

    # 1チャンクの合成に許す最大秒数。VOICEPEAK はまれに異常終了後もプロセスが
    # 応答を返さずハングすることがあり、放置すると永久にブロックしてしまう。
    # この時間を超えたら kill してリトライへ回す。
    def timeout_sec = @timeout_sec ||= Config.get("voicepeak.timeout_sec").to_f

    # チャンク（文）を結合する際に間に挟む無音の秒数。
    # 句点区切りのチャンクをそのままつなげると間延びがなく聞き取りにくいため、
    # 一呼吸おける無音を挟む。
    def chunk_gap_sec = @chunk_gap_sec ||= Config.get("voicepeak.chunk_gap_sec").to_f
  end

  # ナレーターは宮舞モカで固定。
  NARRATOR = "Miyamai Moca"

  # VOICEPEAK の 1 回あたり合成できる文字数の上限。
  MAX_CHARS = 140

  # このクラスが work/ に作る回ごとの中間ファイル/ディレクトリの glob パターン。
  # clean が消してよいものを列挙する（wav_* はチャンク wav を入れるディレクトリ）。
  def self.work_globs(work_dir)
    %w[wav_* voice_*.mp3].map { |pat| File.join(work_dir, pat) }
  end

  # @param episode [Episode] 番組コンテキスト（中間ファイル名の date_tag/slot に使う）
  def initialize(work_dir:, episode:)
    @work_dir = work_dir
    @slot = episode.slot
    @date_tag = episode.date_tag
  end

  # 台本テキストを合成し、生成した mp3 のパスを返す。
  def synthesize(script_path)
    abort "VOICEPEAK not found: #{self.class.voicepeak_bin}" unless File.executable?(self.class.voicepeak_bin)

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

      warn "  [#{i + 1}/#{chunks.size}] #{chunk[0, 30]}"
      synthesize_chunk(chunk, path)
      # VOICEPEAK は本来 GUI アプリで、間髪入れず連続起動すると初期化中に
      # クラッシュする。次の起動まで少し間隔を空けて安定させる。
      sleep self.class.interval_sec
      path
    end

    concat_to_mp3(wav_paths, voice_path)
    FileUtils.rm_rf(wav_dir)

    warn "voice: #{voice_path}"
    voice_path
  end

  private

  def voice_path = File.join(@work_dir, "voice_#{@date_tag}_#{@slot}.mp3")

  # 1チャンク（140文字以内のテキスト）を WAV に合成する。
  # 失敗時は指数バックオフ（retry_base_sec * 2**n）で max_retries 回まで再試行する。
  def synthesize_chunk(text, out_path)
    attempt = 0
    begin
      run_voicepeak(text, out_path)
    rescue RuntimeError => e
      attempt += 1
      raise if attempt > self.class.max_retries

      wait = self.class.retry_base_sec * (2**(attempt - 1))
      warn "    synthesis failed (attempt #{attempt}/#{self.class.max_retries}): #{e.message} / retry in #{wait}s"
      sleep wait
      retry
    end
  end

  # VOICEPEAK を 1 回起動して WAV を生成する。失敗・タイムアウト時は RuntimeError を投げる。
  # timeout_sec を超えても終了しなければハングとみなし、プロセスグループごと
  # kill してから RuntimeError を投げる（呼び出し元のリトライで再試行される）。
  def run_voicepeak(text, out_path)
    # 新しいプロセスグループで起動し、ハング時に子孫ごとまとめて kill できるようにする。
    stdin, _stdout, stderr, wait_thr = Open3.popen3(
      self.class.voicepeak_bin, "--narrator", NARRATOR, "--say", text, "--out", out_path,
      pgroup: true
    )
    stdin.close
    pgid = Process.getpgid(wait_thr.pid)

    unless wait_thr.join(self.class.timeout_sec)
      kill_process_group(pgid)
      raise "VOICEPEAK did not respond within #{self.class.timeout_sec}s (treated as hang, killed)"
    end

    status = wait_thr.value
    err = stderr.read
    raise "VOICEPEAK synthesis failed: #{err[-300..]}" unless status.success?
    raise "VOICEPEAK did not produce an audio file: #{out_path}" unless File.exist?(out_path)
  ensure
    stderr&.close
  end

  # プロセスグループを TERM → （残っていれば）KILL の順で終了させる。
  def kill_process_group(pgid)
    Process.kill("TERM", -pgid)
    # TERM で落ちる猶予を与えてから、まだ生きていれば強制終了する。
    sleep 0.5
    Process.kill("KILL", -pgid)
  rescue Errno::ESRCH
    # 既に終了済み。何もしない。
  end

  # 台本を合成単位のチャンクに分割する。
  # まず「。」で文に切り、MAX_CHARS を超える文は句読点でさらに詰め込みながら分割する。
  def split_chunks(script)
    script
      .gsub(/\r\n?/, "\n")
      .split(/(?<=。)/) # 「。」の直後で分割（句点は各文に残す）
      .map(&:strip)
      .reject(&:empty?)
      .flat_map { |sentence| split_long_sentence(sentence) }
  end

  # MAX_CHARS を超える1文を、読点（、）優先で MAX_CHARS 以内の断片に分ける。
  # 読点でも切れない場合は文字数で強制的に切る。
  def split_long_sentence(sentence)
    return [sentence] if sentence.length <= MAX_CHARS

    chunks = []
    buffer = +""
    sentence.split(/(?<=、)/).each do |part|
      # 読点区切りでも1つが長すぎる場合は文字数で刻む。
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
  # チャンク間には chunk_gap_sec 秒の無音を挟み、文の切れ目に一呼吸おく。
  def concat_to_mp3(wav_paths, output)
    chunk_gap_sec = self.class.chunk_gap_sec
    silence = Tempfile.new(["silence", ".wav"])
    silence.close
    generate_silence(silence.path, chunk_gap_sec) if chunk_gap_sec.positive?

    list = Tempfile.new(["concat", ".txt"])
    wav_paths.each_with_index do |p, i|
      list.puts("file '#{p}'")
      list.puts("file '#{silence.path}'") if chunk_gap_sec.positive? && i < wav_paths.size - 1
    end
    list.close

    _out, err, status = Open3.capture3(
      "ffmpeg", "-y", "-f", "concat", "-safe", "0",
      "-i", list.path, "-c:a", "libmp3lame", "-q:a", "4", output
    )
    raise "ffmpeg concat failed: #{err[-300..]}" unless status.success?
  ensure
    list&.unlink
    silence&.unlink
  end

  # 無音の WAV ファイルを生成する。
  def generate_silence(out_path, duration_sec)
    _out, err, status = Open3.capture3(
      "ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono",
      "-t", duration_sec.to_s, out_path
    )
    raise "silence generation failed: #{err[-300..]}" unless status.success?
  end
end
