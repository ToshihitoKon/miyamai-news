# frozen_string_literal: true

require "rss"

module Internal
  # RSS 2.0 / RDF / Atom フィードの本文をパースし、{ link:, title:, date: } の配列にする。
  # フィード種別ごとの日付フィールドの違いを吸収する以外、フィード提供元固有の知識は持たない。
  module FeedParser
    class << self
      # date は掲載日時。取れないソースは nil。
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

      # 同じ記事が末尾スラッシュの有無だけ違う URL でフィードに載ることがあり、素通しすると
      # 呼び出し側が別記事と誤認する。同一性キーとして使う前にここで正規化して吸収する。
      # "https://example.com" と "https://example.com/" も同一視する（パスが空＝ルートを
      # 指す同じ URL のため）。"https://" 自体は消さないよう、スキーム直後の "//" だけは
      # 対象から除く。
      def normalize_link(link)
        link.strip.sub(%r{(?<!:)/+\z}, "")
      end

      private

      # RSS 2.0 / RDF / Atom で日付の入り方が違うので吸収する。
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
