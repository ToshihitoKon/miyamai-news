# frozen_string_literal: true

require "rexml/document"
require_relative "feed_parser"

module Internal
  # はてなブックマーク RSS(RDF) 固有の知識を隔離する。rss gem は hatena 名前空間の要素を
  # 公開しないため、REXML で直接引く。
  module HatenaBookmarks
    class << self
      # フィード本文から link => { "bookmarks" => N } を作る。はてブ以外には
      # hatena:bookmarkcount が無いので空ハッシュになる。文字列キーの理由は
      # feed_cache.rb と共通（CLAUDE.md 参照）。
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

      # FeedCache の extra からブックマーク数を取り出す。extra が nil、または
      # このモジュールで付与したものでなければ 0 になる。
      def count_of(extra) = extra&.fetch("bookmarks", 0).to_i
    end
  end
end
