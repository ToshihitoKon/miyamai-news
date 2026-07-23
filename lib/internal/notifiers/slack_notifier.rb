# frozen_string_literal: true

require_relative "slack_client"
require_relative "chunker"

module Internal
  module Notifiers
    # facts ファイル全文を Slack へ投稿する。親メッセージ（概要＋カテゴリ・記事タイトル
    # 一覧）を投稿し、その ts を使ってカテゴリ単位の全文をスレッド返信する
    # （incoming webhook はスレッド返信ができないため Slack Web API を使う設計判断の
    # 理由は CLAUDE.md「Notifier」参照）。
    class SlackNotifier
      # メッセージ1通あたりの文字数上限。Slack のハード上限そのものではなく、装飾込みで
      # 無理なく読める分量の運用上の目安値（VoiceSynthesizer::MAX_CHARS と同様、
      # 変更頻度の低い値のため config 化しない）。
      MESSAGE_LIMIT = 3000

      def initialize(bot_token:, channel:)
        @client = SlackClient.new(bot_token: bot_token)
        @channel = channel
      end

      # parsed: Internal::FactsFullText.parse の戻り値。raw_text はパース失敗時の
      # フォールバック用の生テキスト。
      def notify(parsed, raw_text:, episode_label:)
        if parsed.ok
          notify_structured(parsed, episode_label: episode_label)
        else
          warn "facts.md format unrecognized for Slack, falling back to raw chunking"
          notify_raw(raw_text, episode_label: episode_label)
        end
      end

      private

      def notify_structured(parsed, episode_label:)
        parent = @client.post_message(channel: @channel, text: build_overview(parsed, episode_label: episode_label))
        unless parent.ok
          warn "slack parent post failed, skipping thread replies: #{parent.error}"
          return
        end

        parsed.categories.each { |category| post_category_thread(category, thread_ts: parent.ts) }
      end

      # 親メッセージに現れるのは概要とカテゴリ・記事タイトル一覧のみ。各カテゴリの
      # 全文（URL・要点要約含む）はスレッド返信に回す（親メッセージの文字数を抑えるため）。
      def build_overview(parsed, episode_label:)
        lines = ["*#{episode_label} 技術ニュース digest*", ""]
        parsed.categories.each do |category|
          lines << "*#{category.label}*"
          category.articles.each { |article| lines << "・[#{article.kind}] #{article.title}" }
          lines << ""
        end
        lines.join("\n")
      end

      # 1カテゴリ分の全文（記事の raw_lines をそのまま連結）を、必要なら複数メッセージに
      # 分割して同じ thread_ts へ返信する。1通の失敗は warn して残りのカテゴリ・チャンクの
      # 投稿を継続する（Publisher#run の即abortパターンとは異なる。CLAUDE.md 参照）。
      def post_category_thread(category, thread_ts:)
        blocks = category.articles.map { |article| article.raw_lines.join("\n") }
        chunks = Chunker.pack(blocks, limit: MESSAGE_LIMIT)

        chunks.each_with_index do |chunk, i|
          text = i.zero? ? "*#{category.label}*\n\n#{chunk}" : chunk
          res = @client.post_message(channel: @channel, text: text, thread_ts: thread_ts)
          warn "slack thread reply failed (#{category.label} ##{i + 1}): #{res.error}" unless res.ok
        end
      end

      def notify_raw(raw_text, episode_label:)
        parent = @client.post_message(channel: @channel, text: "*#{episode_label} 技術ニュース digest*")
        unless parent.ok
          warn "slack parent post failed, skipping thread replies: #{parent.error}"
          return
        end

        Chunker.pack([raw_text], limit: MESSAGE_LIMIT).each do |chunk|
          res = @client.post_message(channel: @channel, text: chunk, thread_ts: parent.ts)
          warn "slack raw chunk post failed: #{res.error}" unless res.ok
        end
      end
    end
  end
end
