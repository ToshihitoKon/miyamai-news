# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"
require_relative "config"

module Internal
  # 新規エピソードの publish を Cloudflare Worker の /notify へ知らせるだけの
  # 薄いクライアント。購読者の有無・件数・送信成否は一切知らない。
  class EpisodeNotifier
    # config.yaml に web_push セクションが無ければ機能自体を無効化する。
    def self.from_config
      cfg = ::Config.web_push
      return NullNotifier.new unless cfg

      new(base_url: ::Config.cloudflare.public_base)
    end

    def initialize(base_url:, secret: nil)
      @base_url = base_url
      @secret = secret
    end

    def notify(title:, body:, url:)
      payload = JSON.generate({ title: title, body: body, url: url })
      request = Net::HTTP::Post.new(notify_uri)
      request.body = payload
      request["Content-Type"] = "application/json"
      request["X-Signature"] = sign(payload)

      response = Net::HTTP.start(notify_uri.hostname, notify_uri.port, use_ssl: notify_uri.scheme == "https") do |http|
        http.request(request)
      end
      warn "  ! web push notify returned #{response.code} (site deploy already succeeded)" unless response.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      warn "  ! web push notify failed (site deploy already succeeded): #{e.message}"
    end

    private

    def notify_uri = URI.join(@base_url, "/notify")

    def sign(body)
      digest = OpenSSL::Digest.new("SHA256")
      [OpenSSL::HMAC.digest(digest, secret, body)].pack("m0")
    end

    def secret
      @secret ||= ENV["WEB_PUSH_NOTIFY_SECRET"] or
        raise KeyError, "missing environment variable: WEB_PUSH_NOTIFY_SECRET"
    end
  end

  # web_push 未設定時の no-op。呼び出し側は Config.web_push の有無を意識せずに済む。
  class NullNotifier
    def notify(*, **) = nil
  end
end
