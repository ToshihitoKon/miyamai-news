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

  # パイプラインの工程と、その到達順序。値が大きいほど後段まで進む。
  #   digest:     RSS収集 → AI選別 → facts抽出まで。
  #   script:     digest の続きから、人間が読む台本（TTS 整形前）まで。
  #   handoff:    script の続きから TTS 整形・収集 window の確定・台本一式の R2 への受け渡しまで。
  #   synthesize: handoff の続きから音声合成・BGM合成まで。
  #   publish:    dist/ の音声を公開する。
  STAGE_ORDER = { "digest" => 0, "script" => 1, "handoff" => 2, "synthesize" => 3, "publish" => 4 }.freeze
  STAGES = STAGE_ORDER.keys.freeze

  # どの工程でも必須のセクション。
  REQUIRED_SECTIONS_BASE = %w[cloudflare].freeze

  # 各工程が使う config のトップレベルセクション名。
  REQUIRED_SECTIONS = {
    "digest" => %w[ai_agent program_details rss_feed_sources collect],
    "script" => %w[],
    "handoff" => %w[],
    "synthesize" => %w[voicepeak mixer assets],
    "publish" => %w[assets ai_agent],
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

    def until_stage = app_config.pipeline.until

    def cloudflare = app_config.cloudflare
    def assets = app_config.assets
    def voicepeak = app_config.voicepeak
    def ai_agent = app_config.ai_agent
    def program_details = app_config.program_details
    def collect = app_config.collect
    def rss_feed_sources = app_config.rss_feed_sources
    def mixer = app_config.mixer
    def web_push = app_config.web_push

    # from から stage までの工程に必須のトップレベルセクションが揃っているか一括検証する。
    def validate_for!(stage, from: STAGES.first)
      [from, stage].each do |s|
        raise ArgumentError, "unknown pipeline stage: #{s} (must be one of: #{STAGES.join(', ')})" unless STAGE_ORDER.key?(s)
      end

      validate_sections!(*required_sections_for(from, stage), context: "stages #{from}..#{stage}")
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

    def required_sections_for(from, stage)
      stages = STAGES[STAGE_ORDER[from]..STAGE_ORDER[stage]]
      (REQUIRED_SECTIONS_BASE + stages.flat_map { |s| REQUIRED_SECTIONS.fetch(s) }).uniq
    end

    def app_config
      @app_config ||= load_app_config
    end

    def load_app_config
      data = raw_data
      ensure_no_legacy_keys!(data)
      Internal::Config::AppConfig.new(data).tap { |cfg| ensure_known_stage!(cfg.pipeline.until) }
    rescue Dry::Struct::Error, Psych::Exception => e
      raise InvalidConfigError, "invalid config: #{e.message}"
    end

    def ensure_no_legacy_keys!(data)
      pipeline = data.is_a?(Hash) ? data["pipeline"] : nil
      return unless pipeline.is_a?(Hash) && pipeline.key?("mode")

      raise InvalidConfigError, "invalid config: pipeline.mode was renamed to pipeline.until (#{STAGES.join('/')})"
    end

    def ensure_known_stage!(stage)
      return if STAGE_ORDER.key?(stage)

      raise InvalidConfigError, "invalid config: pipeline.until must be one of #{STAGES.join('/')}, got #{stage}"
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
