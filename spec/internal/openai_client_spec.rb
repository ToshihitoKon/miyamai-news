# frozen_string_literal: true

require "spec_helper"
require "internal/openai_client"

RSpec.describe Internal::OpenAiClient do
  subject(:client) { described_class.new(api_key: "sk-test", timeout_sec: 60, max_retries: 1, retry_base_sec: 0) }

  let(:http) { instance_double(Net::HTTP, "use_ssl=": nil, "read_timeout=": nil) }
  let(:sent_bodies) { [] }

  before do
    allow(Net::HTTP).to receive(:new).with("api.openai.com", 443).and_return(http)
    allow(client).to receive(:sleep)
  end

  def http_response(klass, code, body)
    res = klass.new("1.1", code, "")
    allow(res).to receive(:body).and_return(JSON.generate(body))
    res
  end

  def completed(outputs)
    {
      "status" => "completed",
      "output" => [
        { "type" => "web_search_call", "status" => "completed" },
        { "type" => "message", "content" => [{ "type" => "output_text", "text" => JSON.generate(outputs) }] }
      ],
      "usage" => { "input_tokens" => 10, "output_tokens" => 20 }
    }
  end

  def stub_responses(*responses)
    allow(http).to receive(:request) do |req|
      sent_bodies << JSON.parse(req.body)
      responses.shift
    end
  end

  describe "#generate" do
    it "requests a strict JSON schema with one string property per output and returns the outputs" do
      stub_responses(http_response(Net::HTTPOK, "200", completed("script" => "台本", "used_news" => "一覧")))

      result = client.generate("prompt", model: "gpt-test", output_names: %w[script used_news])

      expect(result.outputs).to eq("script" => "台本", "used_news" => "一覧")
      expect(result.usage).to eq("input_tokens" => 10, "output_tokens" => 20)
      format = sent_bodies.first.dig("text", "format")
      expect(format).to include("type" => "json_schema", "strict" => true)
      expect(format.dig("schema", "required")).to eq(%w[script used_news])
      expect(format.dig("schema", "additionalProperties")).to be false
      expect(sent_bodies.first).not_to include("tools", "reasoning")
    end

    it "adds the web_search tool and reasoning effort only when requested" do
      stub_responses(http_response(Net::HTTPOK, "200", completed("news_facts" => "facts")))

      client.generate("prompt", model: "gpt-test", output_names: %w[news_facts], effort: "high", web_search: true)

      expect(sent_bodies.first["tools"]).to eq([{ "type" => "web_search" }])
      expect(sent_bodies.first["reasoning"]).to eq("effort" => "high")
    end

    it "retries on 429 and succeeds on the next attempt" do
      stub_responses(
        http_response(Net::HTTPTooManyRequests, "429", { "error" => { "message" => "rate limited" } }),
        http_response(Net::HTTPOK, "200", completed("fixed" => "ok"))
      )

      result = client.generate("prompt", model: "gpt-test", output_names: %w[fixed])

      expect(result.outputs).to eq("fixed" => "ok")
      expect(sent_bodies.size).to eq(2)
    end

    it "raises without retrying on a non-retryable HTTP error" do
      stub_responses(http_response(Net::HTTPBadRequest, "400", { "error" => { "message" => "bad schema" } }))

      expect { client.generate("prompt", model: "gpt-test", output_names: %w[fixed]) }
        .to raise_error(described_class::Error, /HTTP 400: bad schema/)
      expect(sent_bodies.size).to eq(1)
    end

    it "wraps a read timeout in Error without retrying" do
      allow(http).to receive(:request).and_raise(Net::ReadTimeout)

      expect { client.generate("prompt", model: "gpt-test", output_names: %w[fixed]) }
        .to raise_error(described_class::Error, /timed out after 60s/)
      expect(http).to have_received(:request).once
    end

    it "wraps a non-JSON success body in Error" do
      res = Net::HTTPOK.new("1.1", "200", "")
      allow(res).to receive(:body).and_return("<html>gateway</html>")
      stub_responses(res)

      expect { client.generate("prompt", model: "gpt-test", output_names: %w[fixed]) }
        .to raise_error(described_class::Error, /non-JSON body/)
    end

    it "raises when the response is incomplete" do
      body = { "status" => "incomplete", "incomplete_details" => { "reason" => "max_output_tokens" }, "output" => [] }
      stub_responses(http_response(Net::HTTPOK, "200", body))

      expect { client.generate("prompt", model: "gpt-test", output_names: %w[fixed]) }
        .to raise_error(described_class::Error, /max_output_tokens/)
    end

    it "raises when the model refuses" do
      body = { "status" => "completed",
               "output" => [{ "type" => "message", "content" => [{ "type" => "refusal", "refusal" => "no" }] }] }
      stub_responses(http_response(Net::HTTPOK, "200", body))

      expect { client.generate("prompt", model: "gpt-test", output_names: %w[fixed]) }
        .to raise_error(described_class::Error, /refused/)
    end

    it "raises when an output is missing from the JSON" do
      stub_responses(http_response(Net::HTTPOK, "200", completed("script" => "台本")))

      expect { client.generate("prompt", model: "gpt-test", output_names: %w[script used_news]) }
        .to raise_error(described_class::Error, /missing outputs: used_news/)
    end

    it "raises before sending a request when the API key is missing" do
      no_key_client = described_class.new(api_key: nil)

      expect { no_key_client.generate("prompt", model: "gpt-test", output_names: %w[fixed]) }
        .to raise_error(described_class::Error, /OPENAI_API_KEY/)
      expect(Net::HTTP).not_to have_received(:new)
    end
  end
end
