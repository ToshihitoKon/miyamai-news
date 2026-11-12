# frozen_string_literal: true

require "json"
require "open3"
require_relative "ai_cli"
require_relative "config"
require_relative "episode_logger"
require_relative "progress"

module Internal
  # 許可ツールを --settings で絞った agy の実行。失敗時は abort せず Error を投げる。
  module RestrictedAgy
    class Error < StandardError; end

    BIN_NAME = "agy"
    RULE_SAFE_NAME_CHAR = /[A-Za-z0-9_.-]/
    RULE_SAFE_PATH = %r{\A(?:#{RULE_SAFE_NAME_CHAR}|/)+\z}
    UNSAFE_PATH_MESSAGE = "only A-Z a-z 0-9 _ . / - can be written in an agy allow rule"

    module_function

    def configured? = File.basename(bin) == BIN_NAME

    def rule_safe_path?(path) = RULE_SAFE_PATH.match?(path)

    def rule_safe_name(name) = name.chars.map { |char| RULE_SAFE_NAME_CHAR.match?(char) ? char : "_" }.join

    def bin = ::Config.ai_agent.bin

    def run(spinner_message, prompt, model:, workdir:, readable_dir: nil)
      argv = [
        bin, "--model", model, "--settings", settings_json(readable_dir),
        "--print-timeout", ::Config.ai_agent.print_timeout,
        "--add-dir", workdir, "-p", prompt
      ]
      spinner = Progress.start("#{spinner_message} [#{BIN_NAME}]")

      start = EpisodeLogger.start_timer
      stdout, stderr, status = begin
        Open3.capture3(*argv, chdir: workdir)
      rescue SystemCallError => e
        spinner.error("(failed)")
        raise Error, "cannot run #{bin}: #{e.message}"
      end
      EpisodeLogger.record(spinner_message, bin: bin, model: model, exit_code: status.exitstatus,
        duration_sec: EpisodeLogger.elapsed_since(start), stdout: stdout, stderr: stderr)

      failure = failure_reason(status, stdout, stderr)
      if failure
        spinner.error("(failed)")
        warn stderr
        raise Error, "agy failed (#{failure})"
      end

      spinner.success("(done)")
      stdout
    end

    def failure_reason(status, stdout, stderr)
      return "print timeout" if stderr.include?(AiCli::PARTIAL_OUTPUT_MARKER)
      return exit_description(status) unless status.success?

      "no output" if stdout.scrub.strip.empty?
    end
    private_class_method :failure_reason

    def exit_description(status)
      status.exitstatus ? "exit #{status.exitstatus}" : "killed by signal #{status.termsig}"
    end
    private_class_method :exit_description

    def settings_json(readable_dir)
      raise Error, "#{UNSAFE_PATH_MESSAGE}: #{readable_dir}" if readable_dir && !rule_safe_path?(readable_dir)

      allow = readable_dir ? ["read_file(#{readable_dir}/*)"] : []
      JSON.generate({ permissions: { allow: allow } })
    end
    private_class_method :settings_json
  end
end
