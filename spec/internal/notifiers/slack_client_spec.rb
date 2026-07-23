# frozen_string_literal: true

require "spec_helper"
require "internal/notifiers/slack_client"

RSpec.describe Internal::Notifiers::SlackClient do
  let(:client) { described_class.new(bot_token: "xoxb-test-token") }

  def http_response(body)
    instance_double(Net::HTTPResponse, body: body)
  end

  before do
    allow(Internal::EpisodeLogger).to receive(:record)
  end

  describe "#post_message" do
    it "returns ok:true with ts on a successful API response" do
      allow(Net::HTTP).to receive(:start).and_return(http_response('{"ok":true,"ts":"1234.5678"}'))

      res = client.post_message(channel: "C1", text: "hello")

      expect(res.ok).to be true
      expect(res.ts).to eq("1234.5678")
      expect(res.error).to be_nil
    end

    it "returns ok:false with the API error string on a Slack-level failure" do
      allow(Net::HTTP).to receive(:start).and_return(http_response('{"ok":false,"error":"channel_not_found"}'))

      res = client.post_message(channel: "C1", text: "hello")

      expect(res.ok).to be false
      expect(res.ts).to be_nil
      expect(res.error).to eq("channel_not_found")
    end

    it "returns ok:false instead of raising when the HTTP call itself fails" do
      allow(Net::HTTP).to receive(:start).and_raise(SocketError, "getaddrinfo failed")

      res = client.post_message(channel: "C1", text: "hello")

      expect(res.ok).to be false
      expect(res.error).to eq("getaddrinfo failed")
    end

    it "sends thread_ts only when given" do
      captured = nil
      allow(Net::HTTP).to receive(:start) do |&block|
        req_double = instance_double(Net::HTTP)
        allow(req_double).to receive(:request) do |req|
          captured = JSON.parse(req.body)
          http_response('{"ok":true,"ts":"1"}')
        end
        block.call(req_double)
      end

      client.post_message(channel: "C1", text: "hello", thread_ts: "999.1")

      expect(captured["thread_ts"]).to eq("999.1")
    end

    it "omits thread_ts from the request body when not given" do
      captured = nil
      allow(Net::HTTP).to receive(:start) do |&block|
        req_double = instance_double(Net::HTTP)
        allow(req_double).to receive(:request) do |req|
          captured = JSON.parse(req.body)
          http_response('{"ok":true,"ts":"1"}')
        end
        block.call(req_double)
      end

      client.post_message(channel: "C1", text: "hello")

      expect(captured).not_to have_key("thread_ts")
    end

    it "does not log the bot token, channel, or text body (secret/body must not be logged)" do
      allow(Net::HTTP).to receive(:start).and_return(http_response('{"ok":true,"ts":"1"}'))

      client.post_message(channel: "C1", text: "secret message body")

      expect(Internal::EpisodeLogger).to have_received(:record) do |_step, **fields|
        expect(fields.values.map(&:to_s)).not_to include(a_string_matching(/xoxb-test-token|secret message body/))
      end
    end
  end
end
