# frozen_string_literal: true

require "yaml"

# config.yaml を読み込み、ドット区切りのキー（例: "gcs.bucket"）で設定値を引くローダー。
# 環境依存値をここに集約し、実体の config.yaml は git 管理外に置く（セットアップは README 参照）。
module Config
  # config.yaml はプロジェクトルート（lib/internal/ の二つ上）に置く。
  ROOT_DIR     = File.expand_path("../..", __dir__)
  DEFAULT_PATH = File.join(ROOT_DIR, "config.yaml")
  SAMPLE_PATH  = File.join(ROOT_DIR, "config.sample.yaml")

  class MissingConfigError < StandardError; end
  class MissingKeyError < StandardError; end

  # pipeline.mode の3段階と、その到達順序。値が大きいほど後段まで進む。
  #   digest:     RSS収集 → AI選別 → facts抽出まで。外部ツール・GCSに依存しない。
  #   synthesize: digest の続きから音声合成・BGM合成まで。
  #   publish:    synthesize の続きから GCS publish まで（フルパイプライン）。
  MODE_ORDER = { "digest" => 0, "synthesize" => 1, "publish" => 2 }.freeze

  # 各 mode で新たに必須になる config キーの差分。累積required_keys_forで合算する。
  # 文字列は単独で必須、配列は「いずれか1つあればよい」候補（ai_agent.model への
  # フォールバックがある role 別モデル指定などに使う）。
  REQUIRED_KEYS_DELTA = {
    "digest" => [
      "ai_agent.bin",
      "ai_agent.model",
      %w[ai_agent.selector_model ai_agent.model],
      %w[ai_agent.extractor_model ai_agent.model],
      "program_details.categories",
      "program_details.total_news_count",
      "rss_feed_sources",
      "collect.lookback_hours",
      "collect.retention_days",
      "collect.fetch_threads",
      "collect.fetch_max_retries",
      "collect.fetch_retry_base_sec",
    ],
    "synthesize" => [
      %w[ai_agent.writer_model ai_agent.model],
      %w[ai_agent.formatter_model ai_agent.model],
      "voicepeak.bin",
      "voicepeak.interval_sec",
      "voicepeak.max_retries",
      "voicepeak.retry_base_sec",
      "voicepeak.timeout_sec",
      "voicepeak.chunk_gap_sec",
      "mixer.bgm_volume",
      "mixer.intro_sec",
      "mixer.tail_sec",
      "mixer.fade_sec",
      "assets.bgm_path",
    ],
    "publish" => [
      "gcs.public_base",
      "gcs.bucket",
      "gcs.retention_episodes",
      "assets.cover_image",
      "assets.icon_image",
    ],
  }.freeze

  class << self
    # 読み込む config.yaml のパス。未設定なら DEFAULT_PATH。
    def path
      @path ||= DEFAULT_PATH
    end

    # config.yaml のパスを差し替える（--config CLI引数・テストのfixture指定用）。
    # 読み込み済みの値をキャッシュしていれば破棄し、次の get で新しいパスから読み直す。
    def path=(new_path)
      @path = new_path
      @data = nil
    end

    # ドット区切りのキーで値を引く。キーが存在せず default が渡されていればそれを返す。
    # 存在せず default も未指定なら MissingKeyError。
    def get(dotted_key, default = :__no_default__)
      value = dig(dotted_key)
      return value unless value.nil?
      return default unless default == :__no_default__

      raise MissingKeyError, "missing config key: #{dotted_key}"
    end

    # pipeline.mode。未指定時は digest（外部ツール・GCSに依存せず最も手軽なため）。
    # フルパイプライン運用を続けるには config.yaml に明示的に publish を設定する。
    def mode
      get("pipeline.mode", "digest")
    end

    # target_mode までに必須の config キーが揃っているか一括検証する。
    # 欠けていれば起動直後にまとめて MissingKeyError を出し、実行途中で中途半端に
    # 失敗するのを防ぐ。
    def validate_for!(target_mode)
      raise ArgumentError, "unknown pipeline mode: #{target_mode}" unless MODE_ORDER.key?(target_mode)

      missing = required_keys_for(target_mode).reject { |key| present?(key) }
      missing << "ai_agent.effort" if get("ai_agent.bin", "claude") == "claude" && !present?("ai_agent.effort")

      return if missing.empty?

      labels = missing.map { |key| Array(key).join(" or ") }
      raise MissingKeyError,
        "missing config keys for pipeline.mode=#{target_mode}:\n" + labels.map { |l| "  - #{l}" }.join("\n")
    end

    private

    # target_mode 自身とそれより手前の全 mode の必須キーを合算する（加算方式）。
    def required_keys_for(target_mode)
      MODE_ORDER[target_mode].downto(0).flat_map { |order| REQUIRED_KEYS_DELTA.fetch(MODE_ORDER.key(order)) }
    end

    # 文字列キーは単独で必須、配列（候補リスト）はいずれか1つ存在すればよい。
    def present?(key_or_candidates)
      Array(key_or_candidates).any? { |key| !dig(key).nil? }
    end

    def dig(dotted_key)
      data.dig(*dotted_key.split("."))
    end

    def data
      @data ||= load_data
    end

    def load_data
      unless File.exist?(path)
        raise MissingConfigError,
          "#{path} not found. " \
          "Run `cp #{File.basename(SAMPLE_PATH)} #{File.basename(DEFAULT_PATH)}` and fill in the values."
      end

      YAML.safe_load_file(path) || {}
    end
  end
end
