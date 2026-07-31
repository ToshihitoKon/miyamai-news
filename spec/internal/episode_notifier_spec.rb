# frozen_string_literal: true

require "spec_helper"
require "internal/episode_notifier"

RSpec.describe Internal::EpisodeNotifier do
  let(:notifier) { described_class.new(base_url: "https://news.example.com", secret: "test-secret") }

  describe "#notify" do
    it "POSTs a signed JSON body to /notify" do
      sent_request = nil
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:start) do |host, port, use_ssl:, &block|
        expect(host).to eq("news.example.com")
        expect(port).to eq(443)
        expect(use_ssl).to be true
        block.call(http)
      end
      allow(http).to receive(:request) { |req| sent_request = req }

      notifier.notify(title: "新しい回", url: "https://news.example.com/")

      body = JSON.parse(sent_request.body)
      expect(body).to eq("title" => "新しい回", "url" => "https://news.example.com/")
      expect(sent_request["Content-Type"]).to eq("application/json")
      expect(sent_request["X-Signature"]).not_to be_empty
    end

    it "signs the same body deterministically for a given secret" do
      digest = OpenSSL::Digest.new("SHA256")
      expected = [OpenSSL::HMAC.digest(digest, "test-secret", '{"title":"t","url":"u"}')].pack("m0")

      sent_request = nil
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:start) { |*, &block| block.call(http) }
      allow(http).to receive(:request) { |req| sent_request = req }

      notifier.notify(title: "t", url: "u")

      expect(sent_request["X-Signature"]).to eq(expected)
    end

    it "warns instead of raising when the HTTP call fails (site deploy already succeeded)" do
      allow(Net::HTTP).to receive(:start).and_raise(SocketError, "getaddrinfo failed")

      expect { notifier.notify(title: "t", url: "u") }.not_to raise_error
    end
  end

  describe ".from_config" do
    it "returns a NullNotifier when web_push is not configured" do
      allow(Config).to receive(:web_push).and_return(nil)

      expect(described_class.from_config).to be_a(Internal::NullNotifier)
    end

    it "builds a notifier using cloudflare.public_base when web_push is configured" do
      allow(Config).to receive(:web_push).and_return(double("web_push", vapid_public_key: "pub"))
      allow(Config).to receive(:cloudflare).and_return(double("cloudflare", public_base: "https://news.example.com"))

      notifier = described_class.from_config

      expect(notifier).to be_a(described_class)
    end
  end
end

RSpec.describe Internal::NullNotifier do
  it "does nothing" do
    expect { described_class.new.notify(title: "t", url: "u") }.not_to raise_error
  end
end
