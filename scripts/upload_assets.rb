#!/usr/bin/env ruby
# frozen_string_literal: true

# 画像などの恒久素材を R2 の assets/ プレフィックスへ置く。
# 版権素材をリポジトリに置かずに済ませるため、実体は R2 だけにある。
#
#   ruby scripts/upload_assets.rb --file miyamai_news.webp            # 計画のみ
#   envchain cloudflare ruby scripts/upload_assets.rb --file a.webp --apply
#
# 既に同じ内容が置かれていれば転送しない。

require "digest"
require_relative "../lib/internal/config"
require_relative "../lib/internal/site"

APPLY = ARGV.include?("--apply")

files = ARGV.each_with_index.filter_map { |a, i| ARGV[i + 1] if a == "--file" }
abort("usage: #{$PROGRAM_NAME} --file <path> [--file <path>...] [--apply]") if files.empty?

CONTENT_TYPES = {
  ".webp" => "image/webp",
  ".png" => "image/png",
  ".jpg" => "image/jpeg",
  ".jpeg" => "image/jpeg",
  ".svg" => "image/svg+xml",
}.freeze

site = Internal::Site.from_config

files.each do |path|
  abort("not found: #{path}") unless File.exist?(path)
  abort("empty file: #{path}") if File.size(path).zero?

  name = File.basename(path)
  type = CONTENT_TYPES[File.extname(name).downcase] or abort("unknown asset type: #{name}")

  if APPLY
    print "#{site.asset_url(name)} ... "
    site.upload_asset(name, path, content_type: type)
    puts "ok"
  else
    puts "  #{path} (#{File.size(path)} bytes, #{type})  ->  #{site.asset_url(name)}"
  end
end

unless APPLY
  puts
  puts "計画のみ表示しました。実行するには --apply を付けてください。"
end
