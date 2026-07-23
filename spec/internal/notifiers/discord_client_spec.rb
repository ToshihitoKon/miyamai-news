# frozen_string_literal: true

require "spec_helper"
require "internal/notifiers/discord_client"

RSpec.describe Internal::Notifiers::DiscordClient do
  let(:client) { described_class.new(webhook_url: "https://discord.example/api/webhooks/1/token") }

  def response(klass, code)
    instance_double(klass, code: code).tap { |res| allow(res).to receive(:is_a?) { |k| k == klass } }
  end

  before { allow(Internal::EpisodeLogger).to receive(:record) }

  describe "#post_message" do
    it "returns true on a 204 success response" do
      allow(Net::HTTP).to receive(:start).and_return(response(Net::HTTPSuccess, "204"))

      expect(client.post_message(content: "hello")).to be true
    end

    it "returns false on a non-success response" do
      allow(Net::HTTP).to receive(:start).and_return(response(Net::HTTPClientError, "400"))

      expect(client.post_message(content: "hello")).to be false
    end

    it "returns false instead of raising when the HTTP call itself fails" do
      allow(Net::HTTP).to receive(:start).and_raise(SocketError, "getaddrinfo failed")

      expect(client.post_message(content: "hello")).to be false
    end

    it "does not log the webhook URL or content body (secret/body must not be logged)" do
      allow(Net::HTTP).to receive(:start).and_return(response(Net::HTTPSuccess, "204"))

      client.post_message(content: "secret discord body")

      expect(Internal::EpisodeLogger).to have_received(:record) do |_step, **fields|
        expect(fields.values.map(&:to_s)).not_to include(a_string_matching(%r{secret discord body|discord.example/api/webhooks}))
      end
    end
  end
end
