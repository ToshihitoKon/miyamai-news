# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "episode_logger"

module Internal
  # 単一 URL の HTTP GET を、リダイレクト追従と指数バックオフ付きリトライで実行する。
  # フィードの内容や用途には関与しない、純粋な取得ユーティリティ。
  class HttpFetcher
    # 追従するリダイレクトの上限ホップ数。無限リダイレクトループでの永久ハングを防ぐ。
    MAX_REDIRECTS = 5

    # @param max_retries [Integer] 最大リトライ回数
    # @param retry_base_sec [Float] 指数バックオフの初期待機秒数
    def initialize(max_retries: 3, retry_base_sec: 2.0)
      @max_retries = max_retries
      @retry_base_sec = retry_base_sec
    end

    # url を取得して本文を返す。失敗時は指数バックオフで max_retries 回まで再試行し、
    # それでも取れなければ例外を送出する（一時的な 502 等を返すサーバーがあるため）。
    def get(url)
      attempt = 0
      begin
        start = Internal::EpisodeLogger.start_timer
        body = get_once(url)
        Internal::EpisodeLogger.record("http_fetch", url: url, attempt: attempt,
          duration_sec: Internal::EpisodeLogger.elapsed_since(start))
        body
      rescue StandardError => e
        attempt += 1
        raise "failed to fetch #{url}: #{e.message}" if attempt > @max_retries

        wait = @retry_base_sec * (2**(attempt - 1))
        warn "  ! fetch failed for #{url} (attempt #{attempt}/#{@max_retries}): #{e.message} / retry in #{wait}s"
        Internal::EpisodeLogger.record("http_fetch", url: url, attempt: attempt, error: e.message, retry_in_sec: wait)
        sleep wait
        retry
      end
    end

    private

    # リダイレクトを MAX_REDIRECTS 回まで追従する。Location は相対URIのことがある
    # （RFC 7231 で許容されており実サーバーでも一般的）ため、直前の URL を基点に
    # URI#merge で解決する。
    def get_once(url)
      current = URI.parse(url)

      MAX_REDIRECTS.times do
        res = Net::HTTP.get_response(current)
        return res.body if res.is_a?(Net::HTTPSuccess)
        raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPRedirection)

        location = res["location"] or raise "HTTP #{res.code} redirect without a Location header"
        current = current.merge(location)
      end

      raise "too many redirects (> #{MAX_REDIRECTS}) starting from #{url}"
    end
  end
end
