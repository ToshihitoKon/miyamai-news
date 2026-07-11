# frozen_string_literal: true

require "yaml"

# config.yaml を読み込み、ドット区切りのキーで設定値を引くためのローダー。
#
# 環境依存する値（VOICEPEAK のパス、BGM・カバー画像のパス、GCS バケット名など）は
# すべて config.yaml に集約する。git 管理下にはダミー値入りの config.sample.yaml
# だけを置き、実体の config.yaml は各自がコピーして書き換える。
#
# 使い方:
#   Config.get("gcs.bucket")            # => "your-bucket"
#   Config.get("voicepeak.timeout_sec") # => 10.0
#   Config.fetch("mixer.bgm_volume", 0.15)  # キー欠落時のフォールバック付き
module Config
  # config.yaml はプロジェクトルート（lib/ の一つ上）に置く。
  ROOT_DIR     = File.expand_path("..", __dir__)
  DEFAULT_PATH = File.join(ROOT_DIR, "config.yaml")
  SAMPLE_PATH  = File.join(ROOT_DIR, "config.sample.yaml")

  class MissingConfigError < StandardError; end
  class MissingKeyError < StandardError; end

  class << self
    # ドット区切りのキーで値を引く。キーが存在しなければ MissingKeyError。
    def get(dotted_key)
      value = dig(dotted_key)
      raise MissingKeyError, "config.yaml に設定がありません: #{dotted_key}" if value.nil?

      value
    end

    # キーが欠けていれば default を返す版。任意項目に使う。
    def fetch(dotted_key, default)
      value = dig(dotted_key)
      value.nil? ? default : value
    end

    # テスト用途などで明示的に読み込み直したいとき用。
    def reload!
      @data = nil
      data
    end

    private

    def dig(dotted_key)
      data.dig(*dotted_key.split("."))
    end

    def data
      @data ||= load_data
    end

    def load_data
      unless File.exist?(DEFAULT_PATH)
        raise MissingConfigError,
              "#{DEFAULT_PATH} がありません。" \
              "`cp #{File.basename(SAMPLE_PATH)} #{File.basename(DEFAULT_PATH)}` してから値を埋めてください。"
      end

      YAML.safe_load_file(DEFAULT_PATH) || {}
    end
  end
end
