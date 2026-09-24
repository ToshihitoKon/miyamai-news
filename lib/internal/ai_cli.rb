# frozen_string_literal: true

require "json"
require "open3"
require "tty-spinner"
require_relative "config"
require_relative "episode_logger"
require_relative "openai_client"

# claude/agy 等の AI CLI、または OpenAI API を呼ぶ共通ロジック。ScriptGenerator
# （selector/extractor/writer/format）と UsedNewsFormatter（used_fix）の双方が使う。
module Internal
  module AiCli
    module_function

    PARTIAL_OUTPUT_MARKER = "returning partial output"
    OPENAI_BIN = "openai"

    # AI 自身がツールでファイルを読み書きするか（OpenAI API では false）。
    def file_io? = ::Config.ai_agent.bin != OPENAI_BIN

    # outputs: 出力名 => 書き込み先パス（file_io? でないときに Ruby 側が書く）。
    def run(spinner_message, prompt, outputs:, model_override: nil, effort_override: :default, fatal: true,
            web_search: false, cleanup_paths_on_timeout: [])
      bin = ::Config.ai_agent.bin
      model = model_override || ::Config.ai_agent.model
      effort = effort_override == :default ? ::Config.ai_agent.effort : effort_override

      log_meta = { bin: bin, model: model }

      if bin == OPENAI_BIN
        run_openai("#{spinner_message} [#{bin}]", prompt, outputs: outputs, model: model, effort: effort,
          web_search: web_search, fatal: fatal, log_meta: log_meta)
      elsif bin == "claude"
        # effort 未設定なら --effort 自体を渡さず、claude CLI 側の既定に任せる。
        effort_args = effort ? ["--effort", effort] : []
        run_with_spinner(
          "#{spinner_message} [#{bin}]",
          "AI CLI failed",
          bin, "-p", "--model", model, *effort_args, "--allowedTools", "Read Write WebFetch",
          stdin_data: prompt, fatal: fatal, log_meta: log_meta,
          cleanup_paths_on_timeout: cleanup_paths_on_timeout
        )
      else
        run_with_spinner(
          "#{spinner_message} [#{bin}]",
          "AI CLI failed",
          bin, "--model", model, "--dangerously-skip-permissions",
          "--print-timeout", ::Config.ai_agent.print_timeout,
          "--add-dir", Dir.pwd, "-p", prompt,
          fatal: fatal, log_meta: log_meta, cleanup_paths_on_timeout: cleanup_paths_on_timeout
        )
      end
    end

    def model_for(role) = ::Config.ai_agent.model_for(role)

    # fatal: false のとき、コマンドが失敗しても abort せず nil を返す（best-effort 用途）。
    # cmd（プロンプト本文を含みうる argv）はログに残さない。
    def run_with_spinner(spinner_message, error_message, *cmd, stdin_data: nil, fatal: true, log_meta: {},
                         cleanup_paths_on_timeout: [])
      spinner = TTY::Spinner.new("[:spinner] #{spinner_message}", format: :dots)
      spinner.auto_spin

      opts = stdin_data ? { stdin_data: stdin_data } : {}
      start = EpisodeLogger.start_timer
      stdout, stderr, status = Open3.capture3(*cmd, **opts)
      EpisodeLogger.record(spinner_message, **log_meta, exit_code: status.exitstatus,
        duration_sec: EpisodeLogger.elapsed_since(start), stdout: stdout, stderr: stderr)

      timed_out = stderr.include?(PARTIAL_OUTPUT_MARKER)
      unless status.success? && !timed_out
        spinner.error("(failed)")
        warn stderr
        cleanup_paths_on_timeout.each { |path| File.delete(path) if File.exist?(path) } if timed_out
        return nil unless fatal

        exit_desc = timed_out ? "print timeout" : "exit #{status.exitstatus}"
        abort "#{error_message} (#{exit_desc})"
      end

      spinner.success("(done)")
      stdout
    end
    private_class_method :run_with_spinner

    # 成功時は outputs の各パスへ書き込んで true を返す。失敗時は何も書かない。
    def run_openai(spinner_message, prompt, outputs:, model:, effort:, web_search:, fatal:, log_meta:)
      spinner = TTY::Spinner.new("[:spinner] #{spinner_message}", format: :dots)
      spinner.auto_spin

      start = EpisodeLogger.start_timer
      client = OpenAiClient.new(timeout_sec: ::Config.ai_agent.request_timeout_sec)
      result = client.generate(prompt, model: model, output_names: outputs.keys, effort: effort, web_search: web_search)
      EpisodeLogger.record(spinner_message, **log_meta, duration_sec: EpisodeLogger.elapsed_since(start),
        usage: JSON.generate(result.usage), stdout: JSON.generate(result.outputs))

      outputs.each { |name, path| File.write(path, result.outputs.fetch(name)) }
      spinner.success("(done)")
      true
    rescue OpenAiClient::Error => e
      EpisodeLogger.record(spinner_message, **log_meta, duration_sec: EpisodeLogger.elapsed_since(start),
        stderr: e.message)
      spinner.error("(failed)")
      warn e.message
      return nil unless fatal

      abort "AI API failed (#{e.message})"
    end
    private_class_method :run_openai
  end
end
