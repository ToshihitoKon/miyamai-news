# frozen_string_literal: true

require "stringio"

# 台本は日本語(UTF-8)前提。ロケール未設定の実行環境(CIコンテナ等)でも
# File.read/write が US-ASCII 扱いにならないよう明示する。
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require_relative "../lib/internal/config"
require_relative "../lib/internal/episode_logger"

# lib/* の Config 参照は初回アクセス時まで遅延される（require 時には読まない）ので、
# 各 spec が対象クラスを require する前に fixture の config.yaml を指すよう差し替えておけば足りる。
Config.path = File.expand_path("fixtures/config.yaml", __dir__)

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |c|
    c.verify_partial_doubles = true
  end

  config.filter_run_when_matching :focus
  config.order = :random
  Kernel.srand config.seed

  # Internal::EpisodeLogger は Config と同じくモジュールレベルの状態(@path)を持つ。
  # ある spec が configure した path (tmpdir 配下) は、その spec の after で
  # tmpdir ごと消えるため、reset せずに残すと後続の無関係な spec が消えた path への
  # 書き込みで失敗する。各 example の前後で必ず未設定状態に戻す。
  config.before { Internal::EpisodeLogger.instance_variable_set(:@path, nil) }

  # テスト対象コードは warn/puts や TTY::Spinner で進捗を $stderr/$stdout に直接書く。
  # CI ログでは rspec 自身の出力（どの例が失敗したか）がこれに埋もれてしまうため、
  # テスト対象の出力先だけ StringIO に差し替えて握りつぶす。失敗時の調査用に、
  # example が失敗したときだけ元の出力先へ書き戻す。
  config.around do |example|
    original_stdout, original_stderr = $stdout, $stderr
    captured_stdout, captured_stderr = StringIO.new, StringIO.new
    $stdout, $stderr = captured_stdout, captured_stderr

    begin
      example.run
    ensure
      $stdout, $stderr = original_stdout, original_stderr
      if example.exception
        warn captured_stdout.string unless captured_stdout.string.empty?
        warn captured_stderr.string unless captured_stderr.string.empty?
      end
    end
  end
end
