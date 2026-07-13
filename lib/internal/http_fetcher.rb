# frozen_string_literal: true

require "net/http"
require "uri"

module Internal
  # 単一 URL の HTTP GET を、リダイレクト追従と指数バックオフ付きリトライで実行する。
  # フィードの内容や用途には関与しない、純粋な取得ユーティリティ。
  class HttpFetcher
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
        get_once(url)
      rescue StandardError => e
        attempt += 1
        raise "#{url} の取得に失敗: #{e.message}" if attempt > @max_retries

        wait = @retry_base_sec * (2**(attempt - 1))
        warn "  ! #{url} の取得に失敗（#{attempt}/#{@max_retries} 回目）: #{e.message} / #{wait}秒後に再試行"
        sleep wait
        retry
      end
    end

    private

    def get_once(url)
      res = Net::HTTP.get_response(URI.parse(url))
      # リダイレクトするサーバーがある（例: GitHub の releases.atom）
      res = Net::HTTP.get_response(URI.parse(res["location"])) if res.is_a?(Net::HTTPRedirection)
      raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      res.body
    end
  end
end
