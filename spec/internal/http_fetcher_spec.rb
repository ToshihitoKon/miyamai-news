# frozen_string_literal: true

require "spec_helper"
require "internal/http_fetcher"

RSpec.describe Internal::HttpFetcher do
  let(:fetcher) { described_class.new(max_retries: 0) }

  def success_response(body)
    instance_double(Net::HTTPSuccess, body: body).tap do |res|
      allow(res).to receive(:is_a?) { |klass| klass == Net::HTTPSuccess }
    end
  end

  def redirect_response(code, location)
    instance_double(Net::HTTPRedirection, code: code).tap do |res|
      allow(res).to receive(:is_a?) { |klass| klass == Net::HTTPRedirection }
      allow(res).to receive(:[]).with("location").and_return(location)
    end
  end

  def failure_response(code)
    instance_double(Net::HTTPResponse, code: code).tap do |res|
      allow(res).to receive(:is_a?).and_return(false)
    end
  end

  describe "#get" do
    it "returns the body on a direct 200 response" do
      allow(Net::HTTP).to receive(:get_response).and_return(success_response("ok"))

      expect(fetcher.get("https://example.com/feed.xml")).to eq("ok")
    end

    it "follows an absolute Location header" do
      responses = [
        redirect_response("301", "https://other.example.com/feed2.xml"),
        success_response("moved")
      ]
      allow(Net::HTTP).to receive(:get_response) { responses.shift }

      expect(fetcher.get("https://example.com/feed.xml")).to eq("moved")
      expect(Net::HTTP).to have_received(:get_response)
        .with(URI.parse("https://other.example.com/feed2.xml"))
    end

    it "resolves a relative Location header against the previous URL" do
      responses = [
        redirect_response("301", "/new-feed.xml"),
        success_response("relative ok")
      ]
      allow(Net::HTTP).to receive(:get_response) { responses.shift }

      expect(fetcher.get("https://example.com/old-feed.xml")).to eq("relative ok")
      expect(Net::HTTP).to have_received(:get_response)
        .with(URI.parse("https://example.com/new-feed.xml"))
    end

    it "follows multiple redirect hops" do
      responses = [
        redirect_response("301", "https://step2.example.com/"),
        redirect_response("302", "https://step3.example.com/"),
        success_response("multi-hop ok")
      ]
      allow(Net::HTTP).to receive(:get_response) { responses.shift }

      expect(fetcher.get("https://example.com/feed.xml")).to eq("multi-hop ok")
    end

    it "raises when redirects exceed the hop limit" do
      allow(Net::HTTP).to receive(:get_response).and_return(redirect_response("301", "https://example.com/loop"))

      expect { fetcher.get("https://example.com/feed.xml") }.to raise_error(/too many redirects/)
    end

    it "raises a descriptive error when a redirect has no Location header" do
      allow(Net::HTTP).to receive(:get_response).and_return(redirect_response("301", nil))

      expect { fetcher.get("https://example.com/feed.xml") }.to raise_error(/redirect without a Location header/)
    end

    it "raises on a non-success, non-redirect response" do
      allow(Net::HTTP).to receive(:get_response).and_return(failure_response("500"))

      expect { fetcher.get("https://example.com/feed.xml") }.to raise_error(/HTTP 500/)
    end

    it "retries on failure and eventually succeeds" do
      fetcher = described_class.new(max_retries: 1, retry_base_sec: 0)
      responses = [failure_response("502"), success_response("recovered")]
      allow(Net::HTTP).to receive(:get_response) { responses.shift }
      allow(fetcher).to receive(:sleep)

      expect(fetcher.get("https://example.com/feed.xml")).to eq("recovered")
    end
  end
end
