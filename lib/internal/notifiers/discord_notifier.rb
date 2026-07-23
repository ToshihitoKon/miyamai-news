# frozen_string_literal: true

require_relative "discord_client"
require_relative "chunker"

module Internal
  module Notifiers
    # facts ファイル全文を Discord へ投稿する。Slack と異なりスレッド概念を使わず、
    # webhook URL への複数メッセージ連続 POST で全文相当を投稿する
    # （詳細は CLAUDE.md「Notifier」参照）。
    class DiscordNotifier
      # Discord API のメッセージ本文の文字数上限（ハード制約）。
      CONTENT_LIMIT = 2000

      def initialize(webhook_url:)
        @client = DiscordClient.new(webhook_url: webhook_url)
      end

      # parsed: Internal::FactsFullText.parse の戻り値。raw_text はパース失敗時の
      # フォールバック用の生テキスト。
      def notify(parsed, raw_text:, episode_label:)
        blocks =
          if parsed.ok
            structured_blocks(parsed)
          else
            warn "facts.md format unrecognized for Discord, falling back to raw chunking"
            [raw_text]
          end

        chunks = Chunker.pack(["**#{episode_label} 技術ニュース digest**"] + blocks, limit: CONTENT_LIMIT)
        chunks.each_with_index do |chunk, i|
          ok = @client.post_message(content: chunk)
          warn "discord post failed (chunk ##{i + 1})" unless ok
          # 1通失敗しても残りは投稿を継続する（Publisher#run の即abortパターンとは
          # 異なる。CLAUDE.md 参照）。
        end
      end

      private

      # カテゴリ見出し＋各記事の全文（raw_lines）を、Chunker が詰める単位（block）の
      # 配列として並べる。
      def structured_blocks(parsed)
        parsed.categories.flat_map do |category|
          ["**#{category.label}**"] + category.articles.map { |article| article.raw_lines.join("\n") }
        end
      end
    end
  end
end
