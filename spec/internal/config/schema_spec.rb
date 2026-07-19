# frozen_string_literal: true

require "spec_helper"
require "yaml"
require "internal/config/schema"

RSpec.describe Internal::Config do
  describe Internal::Config::AiAgent do
    it "falls back role-specific models to model when unset" do
      agent = described_class.new(bin: "claude", model: "claude-opus-4-8", effort: "xhigh")

      expect(agent.model_for(:selector)).to eq("claude-opus-4-8")
    end

    it "prefers the role-specific model when set" do
      agent = described_class.new(
        bin: "claude", model: "claude-opus-4-8", effort: "xhigh", selector_model: "claude-sonnet-5"
      )

      expect(agent.model_for(:selector)).to eq("claude-sonnet-5")
    end
  end

  describe Internal::Config::RssFeedSource do
    it "requires url" do
      expect { described_class.new(name: "none") }.to raise_error(Dry::Struct::Error, /url/)
    end

    it "accepts name and url" do
      expect(described_class.new(name: "single", url: "https://a").url).to eq("https://a")
    end

    it "rejects a priority value outside the allowed enum" do
      expect do
        described_class.new(name: "x", url: "https://a", priority: "medium")
      end.to raise_error(Dry::Struct::Error, /priority/)
    end
  end

  describe Internal::Config::Collect do
    it "defaults fetch_skip_minutes to 5 when absent" do
      collect = described_class.new(
        lookback_hours: 24, retention_days: 30, fetch_threads: 5,
        fetch_max_retries: 3, fetch_retry_base_sec: 2
      )

      expect(collect.fetch_skip_minutes).to eq(5)
    end

    it "defaults used_news_history_episodes to 4 when absent" do
      collect = described_class.new(
        lookback_hours: 24, retention_days: 30, fetch_threads: 5,
        fetch_max_retries: 3, fetch_retry_base_sec: 2
      )

      expect(collect.used_news_history_episodes).to eq(4)
    end
  end

  describe Internal::Config::Category do
    it "requires both label and description" do
      expect { described_class.new(label: "AI") }.to raise_error(Dry::Struct::Error, /description/)
    end
  end

  describe Internal::Config::Mixer do
    it "defaults voice_boost_db to 0.0 when absent" do
      mixer = described_class.new(bgm_volume: 0.2, intro_sec: 3, tail_sec: 3, fade_sec: 4)

      expect(mixer.voice_boost_db).to eq(0.0)
    end

    it "coerces integer-typed seconds fields to Float" do
      mixer = described_class.new(bgm_volume: 0.2, intro_sec: 3, tail_sec: 3, fade_sec: 4)

      expect(mixer.intro_sec).to eq(3.0)
    end
  end

  describe Internal::Config::AppConfig do
    it "builds successfully with every section present" do
      data = YAML.safe_load_file(File.expand_path("../../fixtures/config.yaml", __dir__))

      expect { described_class.new(data) }.not_to raise_error
    end

    it "builds successfully with only the digest-required sections" do
      data = YAML.safe_load_file(File.expand_path("../../fixtures/config_digest.yaml", __dir__))

      cfg = described_class.new(data)
      expect(cfg.gcs).to be_nil
      expect(cfg.voicepeak).to be_nil
    end

    it "defaults pipeline.mode to digest when the pipeline section is absent" do
      cfg = described_class.new({})

      expect(cfg.pipeline.mode).to eq("digest")
    end

    it "raises Dry::Struct::Error when a section has the wrong type" do
      data = YAML.safe_load_file(File.expand_path("../../fixtures/config.yaml", __dir__))
      data["gcs"]["bucket"] = ["not", "a", "string"]

      expect { described_class.new(data) }.to raise_error(Dry::Struct::Error)
    end
  end
end
