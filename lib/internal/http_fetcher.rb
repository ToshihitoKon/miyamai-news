# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "zlib"
require_relative "deadline"
require_relative "episode_logger"

module Internal
  # 単一 URL の HTTP GET を、リダイレクト追従と指数バックオフ付きリトライで実行する。
  # フィードの内容や用途には関与しない、純粋な取得ユーティリティ。
  class HttpFetcher
    # 追従するリダイレクトの上限ホップ数。
    MAX_REDIRECTS = 5

    # 1 リクエストあたりの接続確立・読み取りそれぞれの待ち時間の上限秒数。
    REQUEST_TIMEOUT_SEC = 15

    USER_AGENT = "miyamai-news-bot/1.0 (+https://github.com/ToshihitoKon/miyamai-news)"

    class RetryableStatusError < StandardError; end

    # リトライ対象の失敗。HTTP ステータス由来のものと、通信層の例外（タイムアウト・
    # 接続リセット・名前解決失敗・TLS ハンドシェイク失敗・壊れた応答・途中で切れた gzip 本文など）。
    RETRYABLE_ERRORS = [
      RetryableStatusError,
      Timeout::Error,
      SystemCallError,
      SocketError,
      IOError,
      OpenSSL::SSL::SSLError,
      Net::ProtocolError,
      Net::HTTPBadResponse,
      Net::HTTPHeaderSyntaxError,
      Zlib::Error
    ].freeze

    # @param retry_deadline [Internal::Deadline] 待機明けがこれを過ぎる再試行はしない。全 get で共有する
    # @param retry_base_sec [Float] 指数バックオフの初期待機秒数
    # @param retry_max_interval_sec [Float] 1 回あたりの待機秒数の上限
    def initialize(retry_deadline:, retry_base_sec: 2.0, retry_max_interval_sec: 10.0)
      @retry_deadline = retry_deadline
      @retry_base_sec = retry_base_sec
      @retry_max_interval_sec = retry_max_interval_sec
    end

    # url を取得して本文を返す。RETRYABLE_ERRORS は、待機明けが retry_deadline を過ぎない間だけ
    # 指数バックオフで再試行する。それ以外の失敗と打ち切り時は例外を送出する。
    def get(url)
      attempt = 0
      begin
        start = Internal::EpisodeLogger.start_timer
        body = get_once(url)
      rescue *RETRYABLE_ERRORS => e
        attempt += 1
        wait = [@retry_base_sec * (2**(attempt - 1)), @retry_max_interval_sec].min
        remaining_sec = @retry_deadline.remaining_sec
        give_up(url, attempt, "gave up after #{attempt} attempt(s) (retry deadline reached): #{e.message}") if wait > remaining_sec

        warn "  ! fetch failed for #{url} (attempt #{attempt}, #{remaining_sec.round(1)}s left): #{e.message} / retry in #{wait}s"
        Internal::EpisodeLogger.record("http_fetch", url: url, attempt: attempt, error: e.message, retry_in_sec: wait)
        sleep wait
        retry
      rescue StandardError => e
        give_up(url, attempt + 1, e.message)
      end

      Internal::EpisodeLogger.record("http_fetch", url: url, attempt: attempt,
        duration_sec: Internal::EpisodeLogger.elapsed_since(start))
      body
    end

    private

    def give_up(url, attempt, message)
      Internal::EpisodeLogger.record("http_fetch", url: url, attempt: attempt, error: message, gave_up: true)
      raise "failed to fetch #{url}: #{message}"
    end

    # リダイレクトを MAX_REDIRECTS 回まで追従する。
    def get_once(url)
      current = URI.parse(url)

      (MAX_REDIRECTS + 1).times do
        res = request(current)
        return res.body if res.is_a?(Net::HTTPSuccess)
        raise RetryableStatusError, "HTTP #{res.code}" if retryable_status?(res.code)
        raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPRedirection)

        location = res["location"] or raise "HTTP #{res.code} redirect without a Location header"
        current = current.merge(location)
      end

      raise "too many redirects (> #{MAX_REDIRECTS}) starting from #{url}"
    end

    def request(uri)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: REQUEST_TIMEOUT_SEC, read_timeout: REQUEST_TIMEOUT_SEC) do |http|
        http.request_get(uri, { "User-Agent" => USER_AGENT })
      end
    end

    def retryable_status?(code) = code.start_with?("5") || code == "429"
  end
end
