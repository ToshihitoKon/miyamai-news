# frozen_string_literal: true

require "open3"
require "tempfile"
require "fileutils"
require_relative "config"
require_relative "slot"

class VoiceSynthesizer
  VOICEPEAK_BIN = Config.get("voicepeak.bin")
  # ナレーターは宮舞モカで固定。
  NARRATOR = "Miyamai Moca"

  # VOICEPEAK の 1 回あたり合成できる文字数の上限。
  MAX_CHARS = 140

  def initialize(work_dir:, date: Time.now, slot: Slot.for(date))
    @work_dir = work_dir
    @slot = slot
    @date_tag = date.strftime("%Y%m%d")
  end

  # 台本テキストを合成し、生成した mp3 のパスを返す。
  def synthesize(script_path)
    abort "VOICEPEAK が見つかりません: #{VOICEPEAK_BIN}" unless File.executable?(VOICEPEAK_BIN)

    chunks = split_chunks(File.read(script_path))
    abort "台本が空です: #{script_path}" if chunks.empty?

    warn "ナレーター: #{NARRATOR} / チャンク数: #{chunks.size}"

    wav_dir = File.join(@work_dir, "wav_#{@date_tag}_#{@slot}")
    FileUtils.mkdir_p(wav_dir)

    wav_paths = chunks.each_with_index.map do |chunk, i|
      path = File.join(wav_dir, format("%04d.wav", i))
      # 前回クラッシュした場合に備え、合成済みの WAV が残っていれば再利用して
      # 続きから再開する（合成完了時に wav_dir ごと消えるので、残存＝未完了分）。
      if File.exist?(path)
        warn "  [#{i + 1}/#{chunks.size}] スキップ（合成済み）"
        next path
      end

      warn "  [#{i + 1}/#{chunks.size}] #{chunk[0, 30]}"
      synthesize_chunk(chunk, path)
      # VOICEPEAK は本来 GUI アプリで、間髪入れず連続起動すると初期化中に
      # クラッシュする。次の起動まで少し間隔を空けて安定させる。
      sleep INTERVAL_SEC
      path
    end

    concat_to_mp3(wav_paths, voice_path)
    FileUtils.rm_rf(wav_dir)

    warn "音声を生成: #{voice_path}"
    voice_path
  end

  private

  def voice_path = File.join(@work_dir, "voice_#{@date_tag}_#{@slot}.mp3")

  # 各チャンク合成後に空ける秒数。VOICEPEAK の連続起動によるクラッシュ避け。
  INTERVAL_SEC = Config.get("voicepeak.interval_sec").to_f

  # 合成失敗時のリトライ回数と、指数バックオフの初期待機秒数。
  # VOICEPEAK はまれに初期化タイミングでクラッシュするため、待機を倍々に
  # 伸ばしながら数回やり直せば大抵は成功する。
  MAX_RETRIES = Config.get("voicepeak.max_retries").to_i
  RETRY_BASE_SEC = Config.get("voicepeak.retry_base_sec").to_f

  # 1チャンクの合成に許す最大秒数。VOICEPEAK はまれに異常終了後もプロセスが
  # 応答を返さずハングすることがあり、放置すると永久にブロックしてしまう。
  # この時間を超えたら kill してリトライへ回す。
  TIMEOUT_SEC = Config.get("voicepeak.timeout_sec").to_f

  # 1チャンク（140文字以内のテキスト）を WAV に合成する。
  # 失敗時は指数バックオフ（RETRY_BASE_SEC * 2**n）で MAX_RETRIES 回まで再試行する。
  def synthesize_chunk(text, out_path)
    attempt = 0
    begin
      run_voicepeak(text, out_path)
    rescue RuntimeError => e
      attempt += 1
      raise if attempt > MAX_RETRIES

      wait = RETRY_BASE_SEC * (2**(attempt - 1))
      warn "    合成に失敗（#{attempt}/#{MAX_RETRIES} 回目）: #{e.message} / #{wait}秒後に再試行"
      sleep wait
      retry
    end
  end

  # VOICEPEAK を 1 回起動して WAV を生成する。失敗・タイムアウト時は RuntimeError を投げる。
  # TIMEOUT_SEC を超えても終了しなければハングとみなし、プロセスグループごと
  # kill してから RuntimeError を投げる（呼び出し元のリトライで再試行される）。
  def run_voicepeak(text, out_path)
    # 新しいプロセスグループで起動し、ハング時に子孫ごとまとめて kill できるようにする。
    stdin, _stdout, stderr, wait_thr = Open3.popen3(
      VOICEPEAK_BIN, "--narrator", NARRATOR, "--say", text, "--out", out_path,
      pgroup: true
    )
    stdin.close
    pgid = Process.getpgid(wait_thr.pid)

    unless wait_thr.join(TIMEOUT_SEC)
      kill_process_group(pgid)
      raise "VOICEPEAK が #{TIMEOUT_SEC}秒以内に応答しませんでした（ハングとみなし kill）"
    end

    status = wait_thr.value
    err = stderr.read
    raise "VOICEPEAK での合成に失敗しました: #{err[-300..]}" unless status.success?
    raise "VOICEPEAK が音声ファイルを生成しませんでした: #{out_path}" unless File.exist?(out_path)
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
  # まず「。」で文に切り、140 文字を超える文は句読点でさらに詰め込みながら分割する。
  def split_chunks(script)
    script
      .gsub(/\r\n?/, "\n")
      .split(/(?<=。)/)      # 「。」の直後で分割（句点は各文に残す）
      .map(&:strip)
      .reject(&:empty?)
      .flat_map { |sentence| split_long_sentence(sentence) }
  end

  # 140 文字を超える1文を、読点（、）優先で MAX_CHARS 以内の断片に分ける。
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
  def concat_to_mp3(wav_paths, output)
    list = Tempfile.new(["concat", ".txt"])
    wav_paths.each { |p| list.puts("file '#{p}'") }
    list.close

    _out, err, status = Open3.capture3(
      "ffmpeg", "-y", "-f", "concat", "-safe", "0",
      "-i", list.path, "-c:a", "libmp3lame", "-q:a", "4", output
    )
    raise "ffmpeg での連結に失敗しました: #{err[-300..]}" unless status.success?
  ensure
    list&.unlink
  end
end
