# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "../episode_logger"

module Internal
  module Notifiers
    # Discord webhook への POST 専用クライアント。認証ヘッダーは不要（webhook URL
    # 自体が秘匿情報。詳細は CLAUDE.md「Notifier」参照）。既存の Internal::HttpFetcher
    # は GET 専用の fetch ユーティリティのため流用せず新規実装する。
    #
    # 成功可否のみ true/false で返す。Discord webhook は成功時 204 no content で、
    # Slack の ts のような後続投稿用の識別子を持たないため、SlackClient::Response
    # のような戻り値型は不要。
    class DiscordClient
      def initialize(webhook_url:)
        @webhook_url = webhook_url
      end

      # content・webhook URL はログに残さない（秘匿情報・投稿本文の生ログを残さない
      # 既存方針を踏襲。CLAUDE.md 参照）。
      def post_message(content:)
        start = Internal::EpisodeLogger.start_timer
        res = post_once(content)
        ok = res.is_a?(Net::HTTPSuccess)
        Internal::EpisodeLogger.record("discord_post", ok: ok, status: res.code,
          duration_sec: Internal::EpisodeLogger.elapsed_since(start))
        ok
      rescue StandardError => e
        Internal::EpisodeLogger.record("discord_post", ok: false, error_class: e.class.name)
        false
      end

      private

      def post_once(content)
        uri = URI.parse(@webhook_url)
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json; charset=utf-8"
        req.body = JSON.generate(content: content)

        Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
      end
    end
  end
end
