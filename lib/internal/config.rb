# frozen_string_literal: true

require "yaml"
require_relative "config/schema"

# config.yaml を dry-struct で型付き構造体（AppConfig）にロードし、
# セクション名のメソッド（例: Config.cloudflare.bucket）で設定値を引くローダー。
# 環境依存値をここに集約する（セットアップは README 参照）。
module Config
  # config.yaml はプロジェクトルート（lib/internal/ の二つ上）に置く。
  ROOT_DIR     = File.expand_path("../..", __dir__)
  DEFAULT_PATH = File.join(ROOT_DIR, "config.yaml")
  SAMPLE_PATH  = File.join(ROOT_DIR, "config.sample.yaml")

  class MissingConfigError < StandardError; end
  class MissingKeyError < StandardError; end
  # AppConfig 構築時の型不整合（Dry::Struct::Error）をラップする。
  class InvalidConfigError < StandardError; end

  # pipeline.mode の3段階と、その到達順序。値が大きいほど後段まで進む。
  #   digest:     RSS収集 → AI選別 → facts抽出まで。外部ツール・公開先に依存しない。
  #   synthesize: digest の続きから音声合成・BGM合成まで。
  #   publish:    synthesize の続きから公開まで（フルパイプライン）。
  MODE_ORDER = { "digest" => 0, "synthesize" => 1, "publish" => 2 }.freeze

  # 各 mode で新たに必須になる config のトップレベルセクション名の差分。
  REQUIRED_SECTIONS_DELTA = {
    "digest" => %w[ai_agent program_details rss_feed_sources collect],
    "synthesize" => %w[voicepeak mixer assets],
    "publish" => %w[cloudflare],
  }.freeze

  class << self
    # 読み込む config.yaml のパス。未設定なら DEFAULT_PATH。
    def path
      @path ||= DEFAULT_PATH
    end

    # config.yaml のパスを差し替える（--config CLI引数・テストのfixture指定用）。
    def path=(new_path)
      @path = new_path
      @app_config = load_app_config
    end

    def mode = app_config.pipeline.mode

    def cloudflare = app_config.cloudflare
    def assets = app_config.assets
    def voicepeak = app_config.voicepeak
    def ai_agent = app_config.ai_agent
    def program_details = app_config.program_details
    def collect = app_config.collect
    def rss_feed_sources = app_config.rss_feed_sources
    def mixer = app_config.mixer
    def web_push = app_config.web_push

    # target_mode までに必須のトップレベルセクションが揃っているか一括検証する。
    def validate_for!(target_mode)
      raise ArgumentError, "unknown pipeline mode: #{target_mode}" unless MODE_ORDER.key?(target_mode)

      validate_sections!(*required_sections_for(target_mode), context: "pipeline.mode=#{target_mode}")
    end

    # 公開先の設定が揃っているか検証する。
    def validate_publish_target!
      validate_sections!("cloudflare")
    end

    # 指定したトップレベルセクションが全て揃っているか検証する。
    def validate_sections!(*sections, context: nil)
      cfg = app_config
      missing = sections.reject { |section| cfg.public_send(section) }
      return if missing.empty?

      suffix = context ? " for #{context}" : ""
      raise MissingKeyError,
        "missing config sections#{suffix}:\n" + missing.map { |s| "  - #{s}" }.join("\n")
    end

    private

    # target_mode 自身とそれより手前の全 mode の必須セクションを合算する（加算方式）。
    def required_sections_for(target_mode)
      modes = MODE_ORDER.keys.first(MODE_ORDER[target_mode] + 1)
      modes.flat_map { |mode| REQUIRED_SECTIONS_DELTA.fetch(mode) }
    end

    def app_config
      @app_config ||= load_app_config
    end

    def load_app_config
      Internal::Config::AppConfig.new(raw_data)
    rescue Dry::Struct::Error, Psych::Exception => e
      raise InvalidConfigError, "invalid config: #{e.message}"
    end

    def raw_data
      unless File.exist?(path)
        raise MissingConfigError,
          "#{path} not found. " \
          "Run `cp #{File.basename(SAMPLE_PATH)} #{File.basename(DEFAULT_PATH)}` and fill in the values."
      end

      YAML.safe_load_file(path) || {}
    end
  end
end
