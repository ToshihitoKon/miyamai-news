# frozen_string_literal: true

require "spec_helper"
require "yaml"
require "tmpdir"
require "internal/config"

RSpec.describe Config do
  default_path = File.expand_path("../fixtures/config.yaml", __dir__)

  after { Config.path = default_path }

  describe ".mode" do
    it "returns digest when pipeline.mode is absent" do
      Config.path = File.expand_path("../fixtures/config_digest.yaml", __dir__)

      expect(Config.mode).to eq("digest")
    end

    it "returns the configured mode" do
      expect(Config.mode).to eq("publish")
    end
  end

  describe ".validate_for!" do
    it "raises ArgumentError for an unknown mode" do
      expect { Config.validate_for!("bogus") }.to raise_error(ArgumentError, /unknown pipeline mode/)
    end

    it "passes for the fully configured publish fixture" do
      expect { Config.validate_for!("publish") }.not_to raise_error
    end

    context "with the digest-only fixture" do
      before { Config.path = File.expand_path("../fixtures/config_digest.yaml", __dir__) }

      it "passes for digest" do
        expect { Config.validate_for!("digest") }.not_to raise_error
      end

      it "raises MissingKeyError for synthesize, listing the missing sections" do
        expect { Config.validate_for!("synthesize") }.to raise_error(Config::MissingKeyError, /voicepeak/)
      end

      it "raises MissingKeyError for publish, listing the missing sections" do
        expect { Config.validate_for!("publish") }.to raise_error(Config::MissingKeyError, /gcs/)
      end
    end

    it "raises MissingKeyError when a required section is entirely absent" do
      Config.path = File.expand_path("../fixtures/config_digest.yaml", __dir__)
      data = YAML.safe_load_file(Config.path)
      data.delete("ai_agent")
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config.yaml")
        File.write(path, YAML.dump(data))
        Config.path = path

        expect { Config.validate_for!("digest") }.to raise_error(Config::MissingKeyError, /ai_agent/)
      end
    end

    it "raises InvalidConfigError when a section has a type mismatch" do
      data = YAML.safe_load_file(default_path)
      data["gcs"]["bucket"] = ["not", "a", "string"]
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config.yaml")
        File.write(path, YAML.dump(data))

        expect { Config.path = path }.to raise_error(Config::InvalidConfigError)
      end
    end
  end

  describe ".validate_gcs!" do
    it "passes when gcs is configured" do
      expect { Config.validate_gcs! }.not_to raise_error
    end

    it "raises MissingKeyError when gcs is absent" do
      Config.path = File.expand_path("../fixtures/config_digest.yaml", __dir__)

      expect { Config.validate_gcs! }.to raise_error(Config::MissingKeyError, /gcs/)
    end
  end

  describe "section accessors" do
    it "exposes each top-level section as a typed struct" do
      expect(Config.gcs.bucket).to eq("your-bucket-name")
      expect(Config.ai_agent.model_for(:selector)).to eq("claude-sonnet-5")
      expect(Config.program_details.categories.first.label).to eq("生成AI")
    end

    it "returns nil for a section absent from the loaded config" do
      Config.path = File.expand_path("../fixtures/config_digest.yaml", __dir__)

      expect(Config.gcs).to be_nil
    end
  end
end
