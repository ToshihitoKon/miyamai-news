# frozen_string_literal: true

require "open3"
require "tty-spinner"
require_relative "config"
require_relative "episode_logger"

# claude/agy 等の AI CLI をサブプロセスとして実行する共通ロジック。ScriptGenerator
# （selector/extractor/writer/format）と UsedNewsFormatter（used_fix）の双方が使う。
# Config.ai_agent（グローバル設定）と引数だけで完結し、呼び出し元のインスタンス状態は
# 参照しない。
module Internal
  module AiCli
    module_function

    # effort_override は claude 用の effort を明示的に差し替える（nil なら
    # Config.ai_agent.effort を使う）。fatal: false のとき、失敗しても abort せず
    # nil を返す（used_news 整形修復のように失敗しても実行全体を止めたくない用途向け）。
    def run(spinner_message, prompt, model_override: nil, effort_override: :default, fatal: true)
      bin = ::Config.ai_agent.bin
      model = model_override || ::Config.ai_agent.model

      if bin == "claude"
        effort = effort_override == :default ? ::Config.ai_agent.effort : effort_override
        # effort 未設定なら --effort 自体を渡さず、claude CLI 側の既定に任せる。
        effort_args = effort ? ["--effort", effort] : []
        run_with_spinner(
          "#{spinner_message} [#{bin}]",
          "AI CLI failed",
          # allowedTools は呼び出し元ごとに絞らず常に同じ3つを許可する。実害のある
          # ツールではなく、用途ごとに出し分ける利点が薄いため（CLAUDE.md 参照）。
          bin, "-p", "--model", model, *effort_args, "--allowedTools", "Read Write WebFetch",
          stdin_data: prompt, fatal: fatal, bin: bin, model: model
        )
      else
        run_with_spinner(
          "#{spinner_message} [#{bin}]",
          "AI CLI failed",
          bin, "--model", model, "--dangerously-skip-permissions", "-p", prompt,
          fatal: fatal, bin: bin, model: model
        )
      end
    end

    def model_for(role) = ::Config.ai_agent.model_for(role)

    # fatal: false のとき、コマンドが失敗しても abort せず nil を返す（best-effort 用途）。
    # cmd（プロンプト本文を含みうる argv）はログに残さない。bin/model だけで
    # どのコマンドが実行されたかは十分特定できるうえ、agy 経由の呼び出しは
    # プロンプトが -p の直後の引数として cmd に混ざる（claude は stdin 経由なので
    # 混ざらない）ため、cmd をそのままログへ出すとプロンプト全文が漏れてしまう。
    def run_with_spinner(spinner_message, error_message, *cmd, stdin_data: nil, fatal: true, bin: nil, model: nil)
      spinner = TTY::Spinner.new("[:spinner] #{spinner_message}", format: :dots)
      spinner.auto_spin

      opts = stdin_data ? { stdin_data: stdin_data } : {}
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Open3.capture3(*cmd, **opts)
      duration_sec = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(3)
      EpisodeLogger.record(spinner_message, bin: bin, model: model,
        exit_code: status.exitstatus, duration_sec: duration_sec, stdout: stdout, stderr: stderr)

      unless status.success?
        spinner.error("(failed)")
        warn stderr
        return nil unless fatal

        abort "#{error_message} (exit #{status.exitstatus})"
      end

      spinner.success("(done)")
      stdout
    end
    private_class_method :run_with_spinner
  end
end
