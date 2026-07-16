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
    it "raises when both url and urls are given" do
      expect do
        described_class.new(name: "dup", url: "https://a", urls: ["https://b"])
      end.to raise_error(Dry::Struct::Error, /url または urls/)
    end

    it "raises when neither url nor urls are given" do
      expect { described_class.new(name: "none") }.to raise_error(Dry::Struct::Error, /url または urls/)
    end

    it "accepts url alone" do
      expect(described_class.new(name: "single", url: "https://a").url).to eq("https://a")
    end

    it "accepts urls alone" do
      expect(described_class.new(name: "multi", urls: ["https://a", "https://b"]).urls).to eq(["https://a", "https://b"])
    end

    it "rejects a priority value outside the allowed enum" do
      expect do
        described_class.new(name: "x", url: "https://a", priority: "medium")
      end.to raise_error(Dry::Struct::Error, /priority/)
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
