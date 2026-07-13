# frozen_string_literal: true

require "rexml/document"
require_relative "feed_parser"

module Internal
  # はてなブックマーク RSS(RDF) 固有の知識を隔離する。rss gem は hatena 名前空間の要素を
  # 公開しないため、REXML で直接引く。
  module HatenaBookmarks
    class << self
      # フィード本文から link => { "bookmarks" => N } を作る。はてブ以外のフィードには
      # hatena:bookmarkcount が無いので空ハッシュになる。
      #
      # キーを文字列にしているのは、FeedCache が extra を JSON キャッシュへ書き戻すため。
      # JSON 往復後は必ず文字列キーになるので、往復前後で形を揃えて呼び出し側の扱いを
      # 統一する。
      def call(body)
        doc = REXML::Document.new(body)
        pairs = doc.get_elements("//item").filter_map do |item|
          link = FeedParser.normalize_link(item.elements["link"]&.text.to_s)
          count = item.elements["hatena:bookmarkcount"]&.text&.to_i
          [link, { "bookmarks" => count }] unless link.empty? || count.nil?
        end
        pairs.to_h
      rescue REXML::ParseException
        {}
      end
    end
  end
end
