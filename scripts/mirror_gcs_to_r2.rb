#!/usr/bin/env ruby
# frozen_string_literal: true

# 旧 GCS バケットを正として R2 を追従させるミラー。移行が安定するまでの間、
# GCS 側で publish されるたびに実行して R2 を同じ状態に保つ。
#
#   ruby scripts/mirror_gcs_to_r2.rb --from <bucket>
#   envchain cloudflare ruby scripts/mirror_gcs_to_r2.rb --from <bucket> --apply
#
# 移行元は --from で明示的に渡す。config.gcs.bucket は誤 publish を防ぐために
# 実在しない名前へ書き換えられていることがあり、移行元として信用できない。
# GCS 側は読み取りのみで、書き換えも削除もしない。
#
# 何度実行しても同じ結果になる（既に同じ内容が R2 にあれば転送しない）。

require "csv"
require "digest"
require "open3"
require "tmpdir"
require_relative "../lib/internal/config"
require_relative "../lib/internal/site"

APPLY = ARGV.include?("--apply")
SOURCE_BUCKET = ARGV[ARGV.index("--from") + 1] if ARGV.include?("--from")
abort("usage: #{$PROGRAM_NAME} --from <gcs-bucket> [--apply]") unless SOURCE_BUCKET

EPISODE_SUFFIXES = [".mp3", ".used.txt", ".used.html", ".transcript.txt"].freeze

CONTENT_TYPES = {
  ".mp3" => "episodes/mpeg",
  ".used.txt" => "text/plain; charset=utf-8",
  ".used.html" => "text/html; charset=utf-8",
  ".transcript.txt" => "text/plain; charset=utf-8",
}.freeze

def suffix_of(name) = EPISODE_SUFFIXES.find { |s| name.end_with?(s) }

def list_gcs(prefix = "")
  out, err, status = Open3.capture3("gcloud", "storage", "ls", "gs://#{SOURCE_BUCKET}/#{prefix}")
  return [] if !status.success? && err.include?("matched no objects")
  abort("gcloud storage ls failed: #{err}") unless status.success?

  out.lines.map(&:chomp).reject { |l| l.end_with?("/") }
    .map { |l| l.sub("gs://#{SOURCE_BUCKET}/", "") }
end

def download(object, to)
  ok = system("gcloud", "storage", "cp", "gs://#{SOURCE_BUCKET}/#{object}", to,
    out: File::NULL, err: File::NULL)
  abort("download failed: #{object}") unless ok
  to
end

def read_gcs(object)
  Dir.mktmpdir { |dir| File.read(download(object, File.join(dir, "obj"))) }
end

site = Internal::Site.from_config
storage = site.instance_variable_get(:@storage)

ledger_csv = read_gcs("archives.csv")
kept = CSV.parse(ledger_csv).map { |r| r[1] }.compact
puts "GCS 台帳: #{kept.size} 件"

# R2 の現状を 1 度だけ引いて、以降はローカルで突き合わせる。
present = (storage.list("#{storage.episode_prefix}/") + storage.list(storage.archive_prefix)).to_set
puts "R2 既存:  #{present.size} 件"

copies = []
moves = []

(list_gcs + list_gcs("archived/")).each do |object|
  name = File.basename(object)
  suffix = suffix_of(name)
  next unless suffix

  mp3 = name.sub(/#{Regexp.escape(suffix)}\z/, ".mp3")
  retired = !kept.include?(mp3)
  dest = retired ? storage.archive_key(name) : storage.episode_key(name)
  other = retired ? storage.episode_key(name) : storage.archive_key(name)

  if present.include?(dest)
    next # 既に正しい場所にある
  elsif present.include?(other)
    moves << { from: other, to: dest } # 保持/退避の状態だけ変わった
  else
    copies << { src: object, dest: dest, content_type: CONTENT_TYPES.fetch(suffix) }
  end
end

ledger_changed = !storage.exist?("archives.csv") ||
  Digest::SHA256.hexdigest(storage.get("archives.csv")) != Digest::SHA256.hexdigest(ledger_csv)

puts
puts "新規コピー: #{copies.size} 件"
puts "退避/復帰:  #{moves.size} 件"
puts "台帳更新:   #{ledger_changed ? 'あり' : 'なし'}"

if copies.empty? && moves.empty? && !ledger_changed
  puts
  puts "R2 は GCS と同期済みです。"
  exit
end

unless APPLY
  puts
  copies.each { |e| puts "  copy  #{e[:src]}  ->  #{e[:dest]}" }
  moves.each { |e| puts "  move  #{e[:from]}  ->  #{e[:to]}" }
  puts "  ledger archives.csv" if ledger_changed
  puts
  puts "計画のみ表示しました。実行するには --apply を付けてください。"
  exit
end

moves.each do |e|
  print "move #{e[:to]} ... "
  storage.move(e[:from], e[:to])
  puts "ok"
end

Dir.mktmpdir("mirror") do |dir|
  copies.each_with_index do |e, i|
    print "[#{i + 1}/#{copies.size}] #{e[:dest]} ... "
    local = download(e[:src], File.join(dir, File.basename(e[:src])))
    storage.put_file(e[:dest], local, content_type: e[:content_type])
    File.delete(local)
    puts "ok"
  end
end

if ledger_changed
  print "ledger archives.csv ... "
  storage.put("archives.csv", ledger_csv, content_type: "text/csv")
  puts "ok"
end

puts
puts "同期しました。"
