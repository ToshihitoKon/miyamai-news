# frozen_string_literal: true

require "yaml"
require_relative "config/schema"

# config.yaml を dry-struct で型付き構造体（AppConfig）にロードし、
# セクション名のメソッド（例: Config.gcs.bucket）で設定値を引くローダー。
# 環境依存値をここに集約し、実体の config.yaml は git 管理外に置く（セットアップは README 参照）。
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
  #   digest:     RSS収集 → AI選別 → facts抽出まで。外部ツール・GCSに依存しない。
  #   synthesize: digest の続きから音声合成・BGM合成まで。
  #   publish:    synthesize の続きから GCS publish まで（フルパイプライン）。
  MODE_ORDER = { "digest" => 0, "synthesize" => 1, "publish" => 2 }.freeze

  # 各 mode で新たに必須になる config のトップレベルセクション名の差分。
  # セクションの要否は mode 次第で変わる運用ルールであり、型の責務ではないため、
  # AppConfig 上は全セクションを任意属性にし、必須判定はここで別途行う。
  REQUIRED_SECTIONS_DELTA = {
    "digest" => %w[ai_agent program_details rss_feed_sources collect],
    "synthesize" => %w[voicepeak mixer assets],
    "publish" => %w[gcs],
  }.freeze

  class << self
    # 読み込む config.yaml のパス。未設定なら DEFAULT_PATH。
    def path
      @path ||= DEFAULT_PATH
    end

    # config.yaml のパスを差し替える（--config CLI引数・テストのfixture指定用）。
    # 差し替えた時点で新しいパスから即座に読み直す（遅延させない。以前は次回アクセス
    # 時まで遅延させていたが、path= の直後に読み込みエラーへ気づけた方が分かりやすい）。
    def path=(new_path)
      @path = new_path
      @app_config = load_app_config
    end

    def mode = app_config.pipeline.mode

    def gcs = app_config.gcs
    def assets = app_config.assets
    def voicepeak = app_config.voicepeak
    def ai_agent = app_config.ai_agent
    def program_details = app_config.program_details
    def collect = app_config.collect
    def rss_feed_sources = app_config.rss_feed_sources
    def mixer = app_config.mixer

    # target_mode までに必須のトップレベルセクションが揃っているか一括検証する。
    # 欠けていれば起動直後にまとめて MissingKeyError を出し、実行途中で中途半端に
    # 失敗するのを防ぐ。
    def validate_for!(target_mode)
      raise ArgumentError, "unknown pipeline mode: #{target_mode}" unless MODE_ORDER.key?(target_mode)

      cfg = app_config
      missing = required_sections_for(target_mode).reject { |section| cfg.public_send(section) }
      return if missing.empty?

      raise MissingKeyError,
        "missing config sections for pipeline.mode=#{target_mode}:\n" + missing.map { |s| "  - #{s}" }.join("\n")
    end

    # gcs セクション単体の存在を検証する。--clean/--ui-only/--clean-archive は
    # pipeline.mode に関わらず Publisher（GCS 操作）を使うため、mode 別の
    # validate_for! では拾えない gcs 単体の欠落をここで見る。
    def validate_gcs!
      return if gcs

      raise MissingKeyError, "missing config section: gcs"
    end

    private

    # target_mode 自身とそれより手前の全 mode の必須セクションを合算する（加算方式）。
    def required_sections_for(target_mode)
      MODE_ORDER[target_mode].downto(0).flat_map { |order| REQUIRED_SECTIONS_DELTA.fetch(MODE_ORDER.key(order)) }
    end

    # path= を経ていない初回アクセス時だけ、DEFAULT_PATH から遅延ロードする。
    def app_config
      @app_config ||= load_app_config
    end

    def load_app_config
      Internal::Config::AppConfig.new(raw_data)
    rescue Dry::Struct::Error => e
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
