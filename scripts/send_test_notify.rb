#!/usr/bin/env ruby
# frozen_string_literal: true

# Web Push 購読者へ任意のタイトル・URLで通知を送る（動作確認・手動再送用）。
# 通常の publish フローが呼ぶ Internal::EpisodeNotifier をそのまま使うので、
# 本番の /notify 認証・購読者への配信ロジックと同じ経路を通る。
#
#   ruby scripts/send_test_notify.rb --title "テスト" --url https://example.com # 計画のみ
#   envchain cloudflare ruby scripts/send_test_notify.rb --title "テスト" --url https://example.com --apply

require_relative "../lib/internal/config"
require_relative "../lib/internal/episode_notifier"

APPLY = ARGV.include?("--apply")

def arg_value(name)
  i = ARGV.index(name)
  ARGV[i + 1] if i
end

title = arg_value("--title")
url = arg_value("--url")
abort("usage: #{$PROGRAM_NAME} --title <text> --url <url> [--apply]") if title.nil? || url.nil?
abort("config.yaml に web_push セクションがありません") unless Config.web_push

if APPLY
  Internal::EpisodeNotifier.from_config.notify(title: title, url: url)
  puts "sent: title=#{title.inspect} url=#{url.inspect}"
else
  puts "計画のみ: title=#{title.inspect} url=#{url.inspect}"
  puts
  puts "実行するには --apply を付けてください。"
end
