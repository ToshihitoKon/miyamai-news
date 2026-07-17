# frozen_string_literal: true

require "open3"
require "tempfile"
require "fileutils"
require_relative "internal/config"
require_relative "internal/command_error"

class VoiceSynthesizer
  # ナレーターは宮舞モカで固定。
  NARRATOR = "Miyamai Moca"

  # VOICEPEAK の 1 回あたり合成できる文字数の上限。
  MAX_CHARS = 140

  # tts_script 中に埋め込まれた話題転換マーカー。format 段階（format.prompt.erb）で
  # 挿入され、ここで検出・除去したうえで直前チャンクの後に長めの無音を挟む。
  INTERVAL_TAG = /\[interval:(mid|long)\]/

  # 本文を「直後にタグが無ければ末尾まで、あればタグの手前まで」の非貪欲マッチで
  # 繰り返し切り出す。各マッチは [そのテキスト片, 直後のタグ名(無ければnil)] という
  # 組になるため、split の交互配列のように「奇数番目がテキストで偶数番目がタグ」
  # といった順序の暗黙知に頼らずに済む。
  TEXT_WITH_FOLLOWING_TAG = /(.*?)(?:#{INTERVAL_TAG}|\z)/m

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
  # 同じ回の voice_path が既に存在するなら、VOICEPEAK を一切起動せずそれを再利用する
  # （--synthesize-only を使ったブースト値の調整・確認など、音声だけ作り直したい場合に
  # 毎回フルで合成し直さずに済む）。
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
      # VOICEPEAK は本来 GUI アプリで、間髪入れず連続起動すると初期化中に
      # クラッシュする。次の起動まで少し間隔を空けて安定させる。
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

  # 合成失敗時のリトライ回数と、指数バックオフの初期待機秒数。
  # VOICEPEAK はまれに初期化タイミングでクラッシュするため、待機を倍々に
  # 伸ばしながら数回やり直せば大抵は成功する。
  def max_retries = Config.voicepeak.max_retries
  def retry_base_sec = Config.voicepeak.retry_base_sec

  # 1チャンクの合成に許す最大秒数。VOICEPEAK はまれに異常終了後もプロセスが
  # 応答を返さずハングすることがあり、放置すると永久にブロックしてしまう。
  # この時間を超えたら kill してリトライへ回す。
  def timeout_sec = Config.voicepeak.timeout_sec

  # チャンク（文）を結合する際に間に挟む無音の秒数。話題転換のない通常の
  # 文区切り（:short）に使う。句点区切りのチャンクをそのままつなげると間延びが
  # なく聞き取りにくいため、一呼吸おける無音を挟む。
  def chunk_gap_sec = Config.voicepeak.chunk_gap_sec

  # [interval:mid] タグ（個々のニュース記事の切り替え）で挟む無音の秒数。
  def mid_pause_sec = Config.voicepeak.mid_pause_sec

  # [interval:long] タグ（カテゴリ／トピックの転換）で挟む無音の秒数。
  def long_pause_sec = Config.voicepeak.long_pause_sec

  # 1チャンク（140文字以内のテキスト）を WAV に合成する。
  # 失敗時は指数バックオフ（retry_base_sec * 2**n）で max_retries 回まで再試行する。
  def synthesize_chunk(text, out_path)
    attempt = 0
    begin
      run_voicepeak(text, out_path)
    rescue RuntimeError => e
      attempt += 1
      raise if attempt > max_retries

      wait = retry_base_sec * (2**(attempt - 1))
      warn "    synthesis failed (attempt #{attempt}/#{max_retries}): #{e.message} / retry in #{wait}s"
      sleep wait
      retry
    end
  end

  # VOICEPEAK を 1 回起動して WAV を生成する。失敗・タイムアウト時は RuntimeError を投げる。
  # timeout_sec を超えても終了しなければハングとみなし、プロセスグループごと
  # kill してから RuntimeError を投げる（呼び出し元のリトライで再試行される）。
  def run_voicepeak(text, out_path)
    # 新しいプロセスグループで起動し、ハング時に子孫ごとまとめて kill できるようにする。
    stdin, stdout, stderr, wait_thr = Open3.popen3(
      voicepeak_bin, "--narrator", NARRATOR, "--say", text, "--out", out_path,
      pgroup: true
    )
    stdin.close
    pgid = Process.getpgid(wait_thr.pid)

    # stdout/stderr を join 前に別スレッドで読み進める。読まずに join を待つと、
    # 出力がパイプバッファ（約64KB）を超えた際に子プロセスの write がブロックし、
    # 正常動作中でも timeout_sec 超過による偽ハング判定を招くため。
    stdout_reader = Thread.new { stdout.read }
    stderr_reader = Thread.new { stderr.read }

    unless wait_thr.join(timeout_sec)
      kill_process_group(pgid)
      raise "VOICEPEAK did not respond within #{timeout_sec}s (treated as hang, killed)"
    end

    status = wait_thr.value
    err = stderr_reader.value
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
    # TERM で落ちる猶予を与えてから、まだ生きていれば強制終了する。
    sleep 0.5
    Process.kill("KILL", -pgid)
  rescue Errno::ESRCH
    # 既に終了済み。何もしない。
  end

  # 台本を合成単位のチャンクに分割する。戻り値は { text:, pause: } の配列。
  # pause は、そのチャンクの直後に挟む無音の種類（:short/:mid/:long）を表す。
  #
  # まず INTERVAL_TAG（話題転換マーカー）を本文から先に抜き出しておく。「。」分割・
  # MAX_CHARS 分割より後にタグ検出を行うと、分割処理がタグ文字列の途中を横切って
  # タグを壊してしまう恐れがあるため、この順序を守る。
  def split_chunks(script)
    normalized = script.gsub(/\r\n?/, "\n")

    # 各要素が [そのテキスト片, 直後のタグ(あれば:mid/:long)] の組になる。
    # 末尾には空文字列＋タグなしの組が必ず1つ余分に付くため取り除く。
    text_and_pause = normalized.scan(TEXT_WITH_FOLLOWING_TAG)
      .map { |text, tag| [text, tag&.to_sym] }
    text_and_pause.pop if text_and_pause.last == ["", nil]

    chunks = []
    text_and_pause.each do |text, pause|
      sentences = text.split(/(?<=。)/) # 「。」の直後で分割（句点は各文に残す）
        .map(&:strip)
        .reject(&:empty?)
        .flat_map { |sentence| split_long_sentence(sentence) }
      # タグの直後に文が続かない場合（連続するタグなど）、この pause は
      # どのチャンクにも乗らず捨てられる。先に出たタグを優先する扱いでよく、
      # 頻度も低いと見込まれるため、直前チャンクへの引き継ぎまでは行わない。
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
  # pauses は wav_paths と同じ長さの配列で、各チャンクの直後に挟む無音の種類
  # （:short/:mid/:long）を表す（末尾要素は無視する。最後のチャンクの後には
  # 何も挟まない）。
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

  # :short/:mid/:long 用の無音 WAV を tempfile として作り、{ kind => Tempfile } を
  # 返す。秒数が0以下の種類は無音を挟まない扱いとし、キー自体を持たない
  # （concat_to_mp3 側は Hash#[] が nil を返すことでスキップする）。
  def generate_silence_set
    { short: chunk_gap_sec, mid: mid_pause_sec, long: long_pause_sec }.filter_map do |kind, sec|
      next unless sec.positive?

      silence = Tempfile.new(["silence_#{kind}", ".wav"])
      silence.close
      generate_silence(silence.path, sec)
      [kind, silence]
    end.to_h
  end

  # 無音の WAV ファイルを生成する。
  def generate_silence(out_path, duration_sec)
    _out, err, status = Open3.capture3(
      "ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono",
      "-t", duration_sec.to_s, out_path
    )
    raise "silence generation failed: #{Internal::CommandError.tail(err)}" unless status.success?
  end
end
