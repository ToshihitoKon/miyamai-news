# frozen_string_literal: true

# 台本は日本語(UTF-8)前提。ロケール未設定の実行環境(CIコンテナ等)でも
# File.read/write が US-ASCII 扱いにならないよう明示する。
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require_relative "../lib/internal/config"

# lib/*.rb は require 時（定数定義）に Config.get を呼ぶため、他の require より前に
# fixture の config.yaml を指すよう差し替える。
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
end
