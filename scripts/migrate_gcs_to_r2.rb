#!/usr/bin/env ruby
# frozen_string_literal: true

# 旧 GCS バケットの公開物を R2 へ移す一度きりの移行スクリプト。
#
#   ruby scripts/migrate_gcs_to_r2.rb --from <bucket>
#   envchain cloudflare ruby scripts/migrate_gcs_to_r2.rb --from <bucket> --apply
#
# 移行元は --from で明示的に渡す。config.gcs.bucket は誤 publish を防ぐために
# 実在しない名前へ書き換えられていることがあり、移行元として信用できない。
# GCS 側は読み取りのみで、書き換えも削除もしない。

require "csv"
require "json"
require "open3"
require "tmpdir"
require_relative "../lib/internal/config"
require_relative "../lib/internal/site"

APPLY = ARGV.include?("--apply")
SOURCE_BUCKET = ARGV[ARGV.index("--from") + 1] if ARGV.include?("--from")
abort("usage: #{$PROGRAM_NAME} --from <gcs-bucket> [--apply]") unless SOURCE_BUCKET

# 台帳に載っている回は配信対象なので audio/ 配下、それ以外の実体は退避済みとして
# archived/ 配下へ置く。index.html / feed.xml / manifest.json は publish が
# 生成し直すので移さない。
EPISODE_SUFFIXES = [".mp3", ".used.txt", ".used.html", ".transcript.txt"].freeze

CONTENT_TYPES = {
  ".mp3" => "audio/mpeg",
  ".used.txt" => "text/plain; charset=utf-8",
  ".used.html" => "text/html; charset=utf-8",
  ".transcript.txt" => "text/plain; charset=utf-8",
}.freeze

def gcs_bucket = SOURCE_BUCKET

def suffix_of(name) = EPISODE_SUFFIXES.find { |s| name.end_with?(s) }

def list_gcs(prefix = "")
  out, err, status = Open3.capture3("gcloud", "storage", "ls", "gs://#{gcs_bucket}/#{prefix}")
  return [] if !status.success? && err.include?("matched no objects")
  abort("gcloud storage ls failed: #{err}") unless status.success?

  out.lines.map(&:chomp).reject { |l| l.end_with?("/") }
    .map { |l| l.sub("gs://#{gcs_bucket}/", "") }
end

def ledger_filenames
  Dir.mktmpdir do |dir|
    path = File.join(dir, "archives.csv")
    ok = system("gcloud", "storage", "cp", "gs://#{gcs_bucket}/archives.csv", path,
      out: File::NULL, err: File::NULL)
    abort("failed to read archives.csv from gs://#{gcs_bucket}") unless ok

    return CSV.read(path).map { |r| r[1] }.compact
  end
end

site = Internal::Site.from_config
storage = site.instance_variable_get(:@storage)
kept = ledger_filenames
puts "台帳に載っている回: #{kept.size} 件"

plan = []
(list_gcs + list_gcs("archived/")).each do |object|
  name = File.basename(object)
  suffix = suffix_of(name)
  next unless suffix

  mp3 = name.sub(/#{Regexp.escape(suffix)}\z/, ".mp3")
  retired = !kept.include?(mp3)
  dest = retired ? storage.archive_key(name) : storage.audio_key(name)
  plan << { src: object, dest: dest, content_type: CONTENT_TYPES.fetch(suffix), retired: retired }
end

plan.sort_by! { |e| [e[:retired] ? 1 : 0, e[:dest]] }
live = plan.count { |e| !e[:retired] }
puts "移行対象: #{plan.size} 件（配信 #{live} / 退避 #{plan.size - live}）"
puts

unless APPLY
  plan.each { |e| puts "  #{e[:src]}  ->  #{e[:dest]}" }
  puts
  puts "計画のみ表示しました。実行するには --apply を付けてください。"
  puts "（GCS 側は読み取りのみ。R2 に既に同じキーがあれば上書きします）"
  exit
end

Dir.mktmpdir("migrate") do |dir|
  plan.each_with_index do |e, i|
    local = File.join(dir, File.basename(e[:src]))
    print "[#{i + 1}/#{plan.size}] #{e[:dest]} ... "
    ok = system("gcloud", "storage", "cp", "gs://#{gcs_bucket}/#{e[:src]}", local,
      out: File::NULL, err: File::NULL)
    abort("download failed: #{e[:src]}") unless ok

    storage.put_file(e[:dest], local, content_type: e[:content_type])
    File.delete(local)
    puts "ok"
  end
end

puts
puts "完了: #{plan.size} 件を R2 へコピーしました。"
puts "archives.csv は publish 時に生成し直されるため移していません。"
