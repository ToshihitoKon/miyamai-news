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

      it "counts cloudflare among the publish-required sections" do
        expect { Config.validate_for!("publish") }.to raise_error(Config::MissingKeyError, /cloudflare/)
      end
    end

    # gcs だけ揃っていて cloudflare が無い config で publish を通してしまうと、
    # 生成物を作りきってからデプロイ段階で落ちる。
    it "raises MissingKeyError for publish when only cloudflare is absent" do
      data = YAML.safe_load_file(default_path)
      data.delete("cloudflare")
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config.yaml")
        File.write(path, YAML.dump(data))
        Config.path = path

        expect { Config.validate_for!("publish") }.to raise_error(Config::MissingKeyError, /cloudflare/)
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

    it "raises MissingConfigError when the config file does not exist" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "nonexistent.yaml")

        expect { Config.path = path }.to raise_error(Config::MissingConfigError, /not found/)
      end
    end

    it "raises InvalidConfigError (not a raw Psych error) on a YAML syntax error" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config.yaml")
        File.write(path, "gcs: [unterminated")

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

  describe ".validate_publish_targets!" do
    it "passes when both gcs and cloudflare are configured" do
      expect { Config.validate_publish_targets! }.not_to raise_error
    end

    # --ui-only は mode 判定を通らないので、配信先の欠落をここで捕まえないと
    # index.html を生成しきってからデプロイ段階で落ちる。
    it "raises MissingKeyError listing every missing publish target" do
      Config.path = File.expand_path("../fixtures/config_digest.yaml", __dir__)

      expect { Config.validate_publish_targets! }
        .to raise_error(Config::MissingKeyError, /gcs.*cloudflare/m)
    end

    it "raises MissingKeyError when only cloudflare is absent" do
      data = YAML.safe_load_file(default_path)
      data.delete("cloudflare")
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config.yaml")
        File.write(path, YAML.dump(data))
        Config.path = path

        expect { Config.validate_publish_targets! }
          .to raise_error(Config::MissingKeyError, /cloudflare/)
      end
    end
  end

  describe "section accessors" do
    it "exposes each top-level section as a typed struct" do
      expect(Config.gcs.bucket).to eq("your-bucket-name")
      expect(Config.cloudflare.public_base).to eq("https://news.example.com")
      expect(Config.ai_agent.model_for(:selector)).to eq("claude-sonnet-5")
      expect(Config.program_details.categories.first.label).to eq("生成AI")
    end

    it "returns nil for a section absent from the loaded config" do
      Config.path = File.expand_path("../fixtures/config_digest.yaml", __dir__)

      expect(Config.gcs).to be_nil
    end
  end
end
