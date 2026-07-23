# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "../episode_logger"

module Internal
  module Notifiers
    # Slack Web API (chat.postMessage) への POST 専用クライアント。既存の
    # Internal::HttpFetcher は GET 専用の fetch ユーティリティで認証ヘッダーの概念を
    # 持たないため流用せず、新規に実装する（詳細は CLAUDE.md「Notifier」参照）。
    #
    # HttpFetcher と異なり、失敗しても例外を投げず常に Response を返す。呼び出し元
    # （SlackNotifier）が ts の有無で成否を判断し、warn して処理を継続できるようにする
    # ため（親メッセージ投稿の失敗でスレッド返信を諦める、といった呼び出し側の判断を
    # 例外ハンドリングではなく戻り値で表現する）。
    class SlackClient
      ENDPOINT = "https://slack.com/api/chat.postMessage"

      # ok=false のとき ts は nil。error は Slack API が返したエラー文字列
      # （例: "channel_not_found"）または例外発生時の例外メッセージ。
      Response = Struct.new(:ok, :ts, :error, keyword_init: true)

      def initialize(bot_token:)
        @bot_token = bot_token
      end

      # thread_ts を指定すればスレッド返信、省略すれば新規メッセージになる。
      # bot_token・channel・text 本文はログに残さない（秘匿情報・投稿本文の生ログを
      # 残さない既存方針を踏襲。CLAUDE.md 参照）。
      def post_message(channel:, text:, thread_ts: nil)
        start = Internal::EpisodeLogger.start_timer
        body = { channel: channel, text: text }
        body[:thread_ts] = thread_ts if thread_ts

        json = post_once(body)
        Internal::EpisodeLogger.record("slack_post", ok: json["ok"],
          duration_sec: Internal::EpisodeLogger.elapsed_since(start))

        Response.new(ok: json["ok"] ? true : false, ts: json["ts"], error: json["error"])
      rescue StandardError => e
        Internal::EpisodeLogger.record("slack_post", ok: false, error_class: e.class.name)
        Response.new(ok: false, ts: nil, error: e.message)
      end

      private

      def post_once(body)
        uri = URI.parse(ENDPOINT)
        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{@bot_token}"
        req["Content-Type"] = "application/json; charset=utf-8"
        req.body = JSON.generate(body)

        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
        JSON.parse(res.body)
      end
    end
  end
end
