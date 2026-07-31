# frozen_string_literal: true

require "spec_helper"

RSpec.describe Config do
  full_config_path = File.expand_path("fixtures/config.yaml", __dir__)

  before { Config.path = full_config_path }
  after { Config.path = full_config_path }

  describe ".validate_sections!" do
    it "全セクションが揃っていれば何も起きない" do
      expect { Config.validate_sections!("cloudflare", "assets") }.not_to raise_error
    end

    it "欠けているセクションがあれば MissingKeyError を送出する" do
      Config.path = File.expand_path("fixtures/config_digest.yaml", __dir__)

      expect { Config.validate_sections!("cloudflare", "assets") }
        .to raise_error(Config::MissingKeyError, /assets/)
    end

    it "揃っているセクションは欠落メッセージに含めない" do
      Config.path = File.expand_path("fixtures/config_digest.yaml", __dir__)

      expect { Config.validate_sections!("ai_agent", "assets") }
        .to raise_error(Config::MissingKeyError) { |e| expect(e.message).not_to include("ai_agent") }
    end
  end
end
