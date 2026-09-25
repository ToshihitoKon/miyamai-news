#!/usr/bin/env ruby
# frozen_string_literal: true

# 手元のパイプラインの内部状態（last_fetch.json・フィードキャッシュ・紹介済み履歴）を
# R2 の state/ へ初回だけ置く。work/ 直下にある旧配置の内部状態は、先に work/state/ へ移す。
# R2 側に状態が既にあれば何もせず終了する。
#
#   bundle exec ruby scripts/seed_remote_state.rb                              # 計画のみ
#   envchain cloudflare bundle exec ruby scripts/seed_remote_state.rb --apply

require "json"
require_relative "../lib/internal/config"
require_relative "../lib/internal/last_fetch_store"
require_relative "../lib/internal/r2_storage"
require_relative "../lib/internal/remote_state"
require_relative "../lib/internal/state_dir"

APPLY = ARGV.include?("--apply")
WORK_DIR = File.expand_path("../work", __dir__)

Config.validate_publish_target!

legacy = StateDir.legacy_entries(WORK_DIR)
unless legacy.empty?
  puts "work/ 直下の内部状態を #{StateDir.path(WORK_DIR).delete_prefix("#{WORK_DIR}/")}/ へ移します:"
  legacy.each { |entry| puts "  #{entry.delete_prefix("#{WORK_DIR}/")}" }
  puts
  StateDir.migrate_legacy!(WORK_DIR) if APPLY
end

state = Internal::RemoteState.new(storage: Internal::R2Storage.from_config, work_dir: WORK_DIR)
files = state.local_files + (APPLY ? [] : legacy)
abort("no pipeline state found in #{WORK_DIR}") if files.empty?

files.each { |path| puts "  #{path.delete_prefix("#{WORK_DIR}/")}#{File.file?(path) ? " (#{File.size(path)} bytes)" : '/'}" }
puts "-> #{Internal::RemoteState::PREFIX} in R2 bucket #{Config.cloudflare.bucket}"

def legacy_pending(last_fetch_path)
  data = JSON.parse(File.read(last_fetch_path))
  data if data.is_a?(Hash) && data["pending_at"]
rescue Errno::ENOENT, JSON::ParserError
  nil
end

pending = [LastFetchStore.path(WORK_DIR), File.join(WORK_DIR, "last_fetch.json")].filter_map { |path| legacy_pending(path) }.first
if pending
  puts
  puts "注意: 未確定の収集（#{pending['pending_episode'] || 'episode 不明'} / #{pending['pending_at']}）は引き継がれません。"
  puts "      収集の起点は最後に確定した時刻のままなので、その回に集めた記事は次の回で集め直されます。"
end

unless APPLY
  puts
  puts "計画のみ表示しました。実行するには --apply を付けてください。"
  exit
end

begin
  state.seed!
  puts "done: seeded #{state.local_files.size} file(s)"
rescue ArgumentError => e
  abort e.message
end
