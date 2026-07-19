#!/usr/bin/env ruby
# frozen_string_literal: true

# 旧・単一ファイル形式のフィードキャッシュ（work/feed_cache.json）を安全に削除できるかを
# 判定して表示する（削除はしない。安全側に倒し、削除は人間が手で行う）。
#
# ## なぜチェックが要るか
# URL 別ファイルへ分割した後、旧台帳は「まだ一度も fetch されていないフィードの seen_at を
# 継承する元」として残している。旧台帳は link 単位のフラット構造で、どの link がどのフィード
# 由来か分からないため、「あるフィードが一巡した」だけでは消せない。まだ初回 fetch していない
# 別フィードが、その初回時に旧台帳を参照する必要が残るからだ。早く消すと初回誤認で seen_at が
# now にリセットされ、旧来から知っていた記事が新着として二重紹介される。
#
# ## 安全条件
#   max(旧台帳の全 entry の seen_at) < now - retention_days
# この時点では、旧台帳が継承しうる seen_at はすべて「新方式でもどのみち purge される領域
# （last_fetched_at < now - retention_days）」に入っている。継承しても保持されない情報しか
# 残っていないので、消しても失う「生きた継承情報」はゼロ。フィードから既に消えた link
# （新方式でも二度と取得されない）も、この条件下では継承価値がない。

require "json"
require "time"
require_relative "../lib/internal/config"

legacy_path = File.join(Config::ROOT_DIR, "work", "feed_cache.json")

unless File.exist?(legacy_path)
  puts "Legacy cache #{legacy_path} does not exist (already removed, or pre-migration)."
  exit 0
end

cache = JSON.parse(File.read(legacy_path))
now = Time.now
cutoff = now - (Config.collect.retention_days * 86_400)

# 旧台帳の全 entry の中で最も新しい seen_at（壊れた値は無視。1 件も無ければ nil）。
latest = cache.filter_map do |_link, meta|
  Time.iso8601(meta["seen_at"]) if meta.is_a?(Hash) && meta["seen_at"]
rescue ArgumentError
  nil
end.max

puts "Legacy cache: #{legacy_path}"
puts "  entries:        #{cache.size}"
puts "  latest seen_at: #{latest&.iso8601 || '(no seen_at)'}"
puts "  delete cutoff:  seen_at < #{cutoff.iso8601} (now - retention_days=#{Config.collect.retention_days}d)"
puts

# latest が nil（seen_at が 1 件も無い）旧台帳は継承する情報が無いので削除可。
if latest.nil? || latest < cutoff
  puts "=> Safe to delete. Run:"
  puts "     rm #{legacy_path}"
else
  remaining_days = ((latest - cutoff) / 86_400.0).ceil
  puts "=> Do not delete yet (about #{remaining_days} more day(s))."
  puts "   Some feeds still have a seen_at within the retention window, used for seen_at"
  puts "   inheritance on a feed's first fetch."
end
