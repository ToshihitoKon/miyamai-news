# frozen_string_literal: true

require "rss"

module Internal
  # RSS 2.0 / RDF / Atom フィードの本文をパースし、{ link:, title:, date: }（date は
  # 掲載日時、取れないソースは nil）の配列にする。フィード種別ごとの日付フィールドの
  # 違いを吸収する以外、フィード提供元固有の知識は持たない。
  module FeedParser
    class << self
      def parse(body)
        feed = RSS::Parser.parse(body, false)
        return [] unless feed

        feed.items.filter_map do |item|
          title = item.respond_to?(:title) && item.title or next
          title = title.respond_to?(:content) ? title.content : title.to_s
          link  = item.link.respond_to?(:href) ? item.link.href : item.link.to_s

          { title: title.strip, link: normalize_link(link), date: item_date(item)&.iso8601 }
        end
      end

      # 末尾スラッシュの有無だけ違う同じ記事の URL を同一視するための正規化。
      # スキーム直後の "//" は対象外にする負の先読みで、"https://" 自体を壊さない。
      def normalize_link(link)
        link.strip.sub(%r{(?<!:)/+\z}, "")
      end

      private

      def item_date(item)
        if item.respond_to?(:updated) && item.updated
          item.updated.content
        elsif item.respond_to?(:date) && item.date
          item.date
        elsif item.respond_to?(:pubDate) && item.pubDate
          item.pubDate
        end
      end
    end
  end
end
