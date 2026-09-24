# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Internal
  # OpenAI Responses API を呼び、出力名ごとの文字列を JSON Schema（Structured Outputs）で
  # 受け取るクライアント。
  class OpenAiClient
    ENDPOINT = URI("https://api.openai.com/v1/responses")
    RETRYABLE_STATUSES = [429, 500, 502, 503, 504].freeze
    RETRYABLE_ERRORS = [Net::OpenTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError].freeze

    class Error < StandardError; end

    RetryableStatus = Class.new(StandardError)
    private_constant :RetryableStatus

    # outputs: 出力名 => 生成テキスト / usage: API が返したトークン使用量（Hash）
    Result = Struct.new(:outputs, :usage, keyword_init: true)

    def initialize(api_key: ENV.fetch("OPENAI_API_KEY", nil), timeout_sec: 900, max_retries: 3, retry_base_sec: 2.0)
      @api_key = api_key
      @timeout_sec = timeout_sec
      @max_retries = max_retries
      @retry_base_sec = retry_base_sec
    end

    def generate(prompt, model:, output_names:, effort: nil, web_search: false)
      raise Error, "missing environment variable: OPENAI_API_KEY" if @api_key.to_s.empty?

      body = request_body(prompt, model:, output_names:, effort:, web_search:)
      response = post_with_retry(body)
      Result.new(outputs: parse_outputs(response, output_names), usage: response["usage"])
    end

    private

    def request_body(prompt, model:, output_names:, effort:, web_search:)
      body = {
        model: model,
        input: prompt,
        text: { format: { type: "json_schema", name: "outputs", strict: true, schema: output_schema(output_names) } }
      }
      body[:reasoning] = { effort: effort } if effort
      body[:tools] = [{ type: "web_search" }] if web_search
      body
    end

    def output_schema(output_names)
      {
        type: "object",
        properties: output_names.to_h { |name| [name, { type: "string" }] },
        required: output_names,
        additionalProperties: false
      }
    end

    def post_with_retry(body)
      attempt = 0
      begin
        post(body)
      rescue *RETRYABLE_ERRORS, RetryableStatus => e
        attempt += 1
        raise Error, "OpenAI API request failed: #{e.message}" if attempt > @max_retries

        wait = @retry_base_sec * (2**(attempt - 1))
        warn "  ! OpenAI API request failed (attempt #{attempt}/#{@max_retries}): #{e.message} / retry in #{wait}s"
        sleep wait
        retry
      rescue Net::ReadTimeout
        raise Error, "OpenAI API request timed out after #{@timeout_sec}s"
      end
    end

    def post(body)
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      http.read_timeout = @timeout_sec

      req = Net::HTTP::Post.new(ENDPOINT)
      req["Authorization"] = "Bearer #{@api_key}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)

      res = http.request(req)
      return parse_json_body(res.body) if res.is_a?(Net::HTTPSuccess)

      message = "HTTP #{res.code}: #{error_message(res.body)}"
      raise RetryableStatus, message if RETRYABLE_STATUSES.include?(res.code.to_i)

      raise Error, "OpenAI API request failed: #{message}"
    end

    def parse_json_body(raw_body)
      JSON.parse(raw_body)
    rescue JSON::ParserError => e
      raise Error, "OpenAI API returned a non-JSON body: #{e.message}"
    end

    def error_message(raw_body)
      JSON.parse(raw_body).dig("error", "message") || raw_body
    rescue JSON::ParserError
      raw_body
    end

    def parse_outputs(response, output_names)
      unless response["status"] == "completed"
        reason = response.dig("incomplete_details", "reason") || response["status"]
        raise Error, "OpenAI API response not completed: #{reason}"
      end

      parsed = JSON.parse(output_text(response))
      missing = output_names.reject { |name| parsed[name].is_a?(String) }
      raise Error, "OpenAI API response is missing outputs: #{missing.join(', ')}" unless missing.empty?

      parsed.slice(*output_names)
    rescue JSON::ParserError => e
      raise Error, "OpenAI API response is not valid JSON: #{e.message}"
    end

    def output_text(response)
      contents = response.fetch("output", []).select { |item| item["type"] == "message" }.flat_map { |item| item["content"] || [] }
      refusal = contents.find { |c| c["type"] == "refusal" }
      raise Error, "OpenAI API refused: #{refusal['refusal']}" if refusal

      contents.select { |c| c["type"] == "output_text" }.map { |c| c["text"] }.join
    end
  end
end
