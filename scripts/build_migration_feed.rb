#!/usr/bin/env ruby
# frozen_string_literal: true

# 旧 feed に移転告知エントリを 1 件足したものを生成する。
# 生成物を旧 URL へ上げると、旧 feed はそこで凍結する（以後更新しない）。
#
#   ruby scripts/build_migration_feed.rb --from <旧 feed.xml> --out <出力先>
#
# Atom には移転を表す標準要素が無く（RFC 4287 の rel は alternate/related/self/
# enclosure/via のみ）、リーダーに追従を強制する手段も無い。そのため
# 「人間に読ませて再購読してもらう告知エントリ」を本体とし、rel="self" と
# canonical の書き換えは best effort として添える。

require "rexml/document"
require "time"

def arg(name)
  i = ARGV.index("--#{name}")
  i && ARGV[i + 1]
end

source = arg("from") or abort("usage: #{$PROGRAM_NAME} --from <feed.xml> --out <path> [--at <RFC3339>]")
out = arg("out") or abort("usage: #{$PROGRAM_NAME} --from <feed.xml> --out <path> [--at <RFC3339>]")
# 告知時刻。既定は現在時刻だが、再生成しても同じ内容になるよう明示指定できる。
announced_at = arg("at") || Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

NEW_BASE = "https://miyamai-news.temama.soy"
NEW_FEED = "#{NEW_BASE}/feed.xml"

# 告知に添える画像は旧 feed と同じ場所（GCS）へ置く。新ドメイン側に置くと、
# 移転先に何かあったとき告知の画像まで一緒に見えなくなる。
NOTICE_IMAGE = arg("image-url")

doc = REXML::Document.new(File.read(source))
feed = doc.elements["feed"] or abort("not an Atom feed: #{source}")

# 告知エントリの id は他のどれとも衝突しない恒久的な値を 1 つ発行する。
# 新 feed 側と同じ tag URI 体系にしておくと、両方購読していても重複しない。
notice_id = "tag:miyamai-news.temama.soy,2026-07-31:feed-moved"
abort("notice already present in #{source}") if doc.to_s.include?(notice_id)

image_html =
  if NOTICE_IMAGE
    %(<p><img src="#{NOTICE_IMAGE}" alt="宮舞モカ" width="600"></p>\n)
  else
    ""
  end

notice = <<~HTML.strip
  #{image_html}<p>この配信は新しい URL へ移転しました。<strong>このフィードはこれ以降更新されません。</strong></p>
  <p>お手数ですが、購読先を新しいフィードへ変更してください。</p>
  <p><a href="#{NEW_FEED}">#{NEW_FEED}</a></p>
  <p>再生ページ: <a href="#{NEW_BASE}/">#{NEW_BASE}/</a></p>
HTML

entry = REXML::Element.new("entry")
{
  "title" => "【重要】フィードの配信先が変わりました",
  "id" => notice_id,
  "updated" => announced_at,
}.each { |name, text| entry.add_element(name).add_text(text) }

link = entry.add_element("link")
link.add_attributes("rel" => "alternate", "type" => "text/html", "href" => "#{NEW_BASE}/")

content = entry.add_element("content")
content.add_attribute("type", "html")
content.add_text(notice)

# 既存エントリより前に置き、リーダーの並びで最初に出るようにする。
first_entry = feed.elements["entry"]
first_entry ? feed.insert_before(first_entry, entry) : feed.add_element(entry)

# feed の updated を動かさないと新着として拾われない。凍結するので 1 回だけ動く。
feed.elements["updated"].text = announced_at

# 機械的な追従の best effort。追従を保証する仕組みは Atom に無い。
feed.elements["link[@rel='self']"]&.add_attribute("href", NEW_FEED)
unless feed.elements["link[@rel='canonical']"]
  canonical = REXML::Element.new("link")
  canonical.add_attributes("rel" => "canonical", "href" => NEW_FEED)
  feed.insert_after(feed.elements["link[@rel='self']"] || feed.elements["title"], canonical)
end

File.write(out, doc.to_s)
puts "wrote #{out}"
puts "  告知 id:   #{notice_id}"
puts "  updated:  #{announced_at}"
puts "  entries:  #{feed.elements.to_a('entry').size}（告知 1 + 既存 #{feed.elements.to_a('entry').size - 1}）"
