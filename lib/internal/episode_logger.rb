# frozen_string_literal: true

require "time"

# 回ごとの実行ログ（AI CLI/VOICEPEAK/HTTP フェッチの stdout・stderr・所要時間・
# リトライ回数等）を work/<date_tag>_<slot>.log に追記するだけの薄い記録係。
# 計測自体は行わず、呼び出し元が用意した値をそのまま書き込む。configure されるまで
# （path が未設定の間）は record が no-op になるので、呼び出し元は configure 済みか
# を毎回気にせず呼べる。
module Internal
  module EpisodeLogger
    module_function

    def configure(path)
      @path = path
      @mutex = Mutex.new
    end

    # work/ に作る回ごとのログファイルの glob パターン（clean 対象のみ）。
    def work_globs(work_dir) = [File.join(work_dir, "*.log")]

    # step: ログ上の見出し（例: "selecting news", "voicepeak_chunk", "http_fetch"）
    # fields: ヘッダー行に "key=value" で並べる任意のメタ情報（duration_sec/model/
    #   bin/exit_code/attempt/url など、呼び出し元が計測・用意する）
    # stdout/stderr: 本文ブロックとして別途書き出す（nil や空文字なら省略する）
    def record(step, stdout: nil, stderr: nil, **fields)
      return unless @path

      lines = ["[#{Time.now.iso8601}] step=#{step} #{fields.map { |k, v| "#{k}=#{v}" }.join(" ")}"]
      lines.push("___STDOUT_START___", stdout, "___STDOUT_END___") if stdout && !stdout.empty?
      lines.push("___STDERR_START___", stderr, "___STDERR_END___") if stderr && !stderr.empty?

      entry = lines.join("\n")
      @mutex.synchronize { File.open(@path, "a") { |f| f.puts(entry) } }
    end
  end
end
