# frozen_string_literal: true

require "spec_helper"
require "internal/http_fetcher"

RSpec.describe Internal::HttpFetcher do
  # 擬似 monotonic clock の 0 秒から 60 秒後が締め切り。
  let(:fetcher) do
    described_class.new(retry_deadline: Internal::Deadline.new(60.0), retry_base_sec: 2, retry_max_interval_sec: 10)
  end
  let(:sleeps) { [] }
  let(:http) { instance_double(Net::HTTP) }

  # sleep した分だけ進む擬似 monotonic clock。リクエストの所要時間は各テストで @clock を進める。
  before do
    @clock = 0.0
    allow(Internal::Deadline).to receive(:now) { @clock }
    allow(Net::HTTP).to receive(:start) { |*, **, &block| block.call(http) }
    allow(fetcher).to receive(:sleep) do |sec|
      sleeps << sec
      @clock += sec
    end
  end

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
      allow(http).to receive(:request_get).and_return(success_response("ok"))

      expect(fetcher.get("https://example.com/feed.xml")).to eq("ok")
    end

    it "sends a self-identifying User-Agent instead of Net::HTTP's default" do
      allow(http).to receive(:request_get).and_return(success_response("ok"))

      fetcher.get("https://example.com/feed.xml")

      expect(http).to have_received(:request_get)
        .with(anything, { "User-Agent" => Internal::HttpFetcher::USER_AGENT })
    end

    it "follows an absolute Location header" do
      responses = [
        redirect_response("301", "https://other.example.com/feed2.xml"),
        success_response("moved")
      ]
      allow(http).to receive(:request_get) { responses.shift }

      expect(fetcher.get("https://example.com/feed.xml")).to eq("moved")
      expect(http).to have_received(:request_get)
        .with(URI.parse("https://other.example.com/feed2.xml"), { "User-Agent" => described_class::USER_AGENT })
    end

    it "resolves a relative Location header against the previous URL" do
      responses = [
        redirect_response("301", "/new-feed.xml"),
        success_response("relative ok")
      ]
      allow(http).to receive(:request_get) { responses.shift }

      expect(fetcher.get("https://example.com/old-feed.xml")).to eq("relative ok")
      expect(http).to have_received(:request_get)
        .with(URI.parse("https://example.com/new-feed.xml"), { "User-Agent" => described_class::USER_AGENT })
    end

    it "follows multiple redirect hops" do
      responses = [
        redirect_response("301", "https://step2.example.com/"),
        redirect_response("302", "https://step3.example.com/"),
        success_response("multi-hop ok")
      ]
      allow(http).to receive(:request_get) { responses.shift }

      expect(fetcher.get("https://example.com/feed.xml")).to eq("multi-hop ok")
    end

    it "bounds the connect and read waits of each request" do
      allow(http).to receive(:request_get).and_return(success_response("ok"))

      fetcher.get("https://example.com/feed.xml")

      expect(Net::HTTP).to have_received(:start).with(
        "example.com", 443,
        use_ssl: true, open_timeout: described_class::REQUEST_TIMEOUT_SEC, read_timeout: described_class::REQUEST_TIMEOUT_SEC
      )
    end

    it "follows exactly MAX_REDIRECTS redirect hops" do
      responses = Array.new(described_class::MAX_REDIRECTS) { |i| redirect_response("301", "https://example.com/hop#{i}") } +
                  [success_response("last hop ok")]
      allow(http).to receive(:request_get) { responses.shift }

      expect(fetcher.get("https://example.com/feed.xml")).to eq("last hop ok")
    end

    it "raises without retrying when redirects exceed the hop limit" do
      allow(http).to receive(:request_get).and_return(redirect_response("301", "https://example.com/loop"))

      expect { fetcher.get("https://example.com/feed.xml") }.to raise_error(/too many redirects/)
      expect(sleeps).to be_empty
    end

    it "raises a descriptive error without retrying when a redirect has no Location header" do
      allow(http).to receive(:request_get).and_return(redirect_response("301", nil))

      expect { fetcher.get("https://example.com/feed.xml") }.to raise_error(/redirect without a Location header/)
      expect(sleeps).to be_empty
    end

    it "raises without retrying on a 4xx response" do
      allow(http).to receive(:request_get).and_return(failure_response("404"))

      expect { fetcher.get("https://example.com/feed.xml") }
        .to raise_error("failed to fetch https://example.com/feed.xml: HTTP 404")
      expect(http).to have_received(:request_get).once
      expect(sleeps).to be_empty
    end

    it "records the give-up in the episode log" do
      allow(http).to receive(:request_get).and_return(failure_response("404"))
      allow(Internal::EpisodeLogger).to receive(:record)

      expect { fetcher.get("https://example.com/feed.xml") }.to raise_error(/HTTP 404/)
      expect(Internal::EpisodeLogger).to have_received(:record)
        .with("http_fetch", url: "https://example.com/feed.xml", attempt: 1, error: "HTTP 404", gave_up: true)
    end

    it "does not refetch when recording a successful fetch fails" do
      allow(http).to receive(:request_get).and_return(success_response("ok"))
      allow(Internal::EpisodeLogger).to receive(:record).and_raise(IOError, "disk full")

      expect { fetcher.get("https://example.com/feed.xml") }.to raise_error(IOError, "disk full")
      expect(http).to have_received(:request_get).once
    end

    it "raises without retrying on an unexpected error such as a programming bug" do
      allow(http).to receive(:request_get).and_raise(NoMethodError, "undefined method 'body'")

      expect { fetcher.get("https://example.com/feed.xml") }.to raise_error(/failed to fetch .*undefined method/)
      expect(http).to have_received(:request_get).once
      expect(sleeps).to be_empty
    end

    it "retries a 5xx response and returns the body once the server recovers" do
      responses = [failure_response("503"), failure_response("502"), success_response("recovered")]
      allow(http).to receive(:request_get) { responses.shift }

      expect(fetcher.get("https://example.com/feed.xml")).to eq("recovered")
      expect(sleeps).to eq([2, 4])
    end

    it "retries 429 Too Many Requests like a 5xx response" do
      responses = [failure_response("429"), success_response("recovered")]
      allow(http).to receive(:request_get) { responses.shift }

      expect(fetcher.get("https://example.com/feed.xml")).to eq("recovered")
      expect(sleeps).to eq([2])
    end

    [
      Net::OpenTimeout,
      Errno::ECONNRESET,
      EOFError,
      SocketError,
      OpenSSL::SSL::SSLError,
      Net::ProtocolError,
      Net::HTTPBadResponse,
      Net::HTTPHeaderSyntaxError,
      Zlib::BufError
    ].each do |error_class|
      it "retries a network-level error (#{error_class})" do
        attempts = 0
        allow(http).to receive(:request_get) do
          attempts += 1
          raise error_class, "transient" if attempts == 1

          success_response("recovered")
        end

        expect(fetcher.get("https://example.com/feed.xml")).to eq("recovered")
        expect(sleeps).to eq([2])
      end
    end

    context "when the server keeps failing with 5xx until after the retry deadline" do
      before do
        responses = Array.new(8) { failure_response("500") } + [success_response("too late")]
        allow(http).to receive(:request_get) { responses.shift }
      end

      it "doubles the wait on each retry but caps it at retry_max_interval_sec" do
        expect { fetcher.get("https://example.com/feed.xml") }.to raise_error(/HTTP 500/)
        expect(sleeps).to eq([2, 4, 8, 10, 10, 10, 10])
      end

      it "gives up once the next wait would end past the retry deadline" do
        # 待機の累計 54 秒の時点で、次の 10 秒待つと締め切りの 60 秒を過ぎるので 8 回目で諦める。
        expect { fetcher.get("https://example.com/feed.xml") }
          .to raise_error(/gave up after 8 attempt\(s\) \(retry deadline reached\): HTTP 500/)
        expect(http).to have_received(:request_get).exactly(8).times
      end
    end

    it "counts the time spent on requests, not only the waits, toward the retry deadline" do
      responses = Array.new(3) { failure_response("500") } + [success_response("too late")]
      allow(http).to receive(:request_get) do
        @clock += 25
        responses.shift
      end

      # 待機の累計は 6 秒だが、リクエスト時間を含めた経過 25+2+25+4+25 = 81 秒が締め切りの
      # 60 秒を過ぎているので 3 回目で諦める。
      expect { fetcher.get("https://example.com/feed.xml") }.to raise_error(/gave up after 3 attempt\(s\)/)
      expect(sleeps).to eq([2, 4])
    end

    it "shares the retry deadline across calls instead of restarting it for each URL" do
      responses = [success_response("ok"), failure_response("500"), success_response("too late")]
      allow(http).to receive(:request_get) { responses.shift }
      fetcher.get("https://example.com/feed.xml")
      @clock = 59.0

      expect { fetcher.get("https://example.com/other.xml") }.to raise_error(/gave up after 1 attempt\(s\)/)
      expect(sleeps).to be_empty
    end

    it "still makes the first attempt after the retry deadline" do
      allow(http).to receive(:request_get).and_return(success_response("ok"))
      @clock = 120.0

      expect(fetcher.get("https://example.com/feed.xml")).to eq("ok")
    end
  end
end
