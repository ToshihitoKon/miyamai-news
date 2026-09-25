#!/usr/bin/env ruby
# frozen_string_literal: true

# 手元の work/ にあるパイプラインの内部状態（last_fetch.json・フィードキャッシュ・紹介済み履歴）を
# R2 の state/ へ初回だけ置く。R2 側に状態が既にあれば何もせず終了する。
#
#   bundle exec ruby scripts/seed_remote_state.rb                              # 計画のみ
#   envchain cloudflare bundle exec ruby scripts/seed_remote_state.rb --apply

require_relative "../lib/internal/config"
require_relative "../lib/internal/r2_storage"
require_relative "../lib/internal/remote_state"

APPLY = ARGV.include?("--apply")
WORK_DIR = File.expand_path("../work", __dir__)

Config.validate_publish_target!
state = Internal::RemoteState.new(storage: Internal::R2Storage.from_config, work_dir: WORK_DIR)

files = state.local_files
abort("no pipeline state found in #{WORK_DIR}") if files.empty?

files.each { |path| puts "  #{path.delete_prefix("#{WORK_DIR}/")} (#{File.size(path)} bytes)" }
puts "#{files.size} file(s) -> #{Internal::RemoteState::PREFIX} in R2 bucket #{Config.cloudflare.bucket}"

unless APPLY
  puts
  puts "計画のみ表示しました。実行するには --apply を付けてください。"
  exit
end

begin
  count = state.seed!
  puts "done: seeded #{count} file(s)"
rescue ArgumentError => e
  abort e.message
end
