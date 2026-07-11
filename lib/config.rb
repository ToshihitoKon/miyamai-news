# frozen_string_literal: true

require "yaml"

# config.yaml を読み込み、ドット区切りのキー（例: "gcs.bucket"）で設定値を引くローダー。
# 環境依存値をここに集約し、実体の config.yaml は git 管理外に置く（セットアップは README 参照）。
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
