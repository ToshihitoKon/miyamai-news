# frozen_string_literal: true

require "dry-struct"
require_relative "types"

module Internal
  module Config
    # YAML由来の文字列キーHashをそのまま渡せるよう、全セクション構造体の
    # 基底クラスでキーをシンボル化する。
    class Base < Dry::Struct
      transform_keys(&:to_sym)
    end

    class Pipeline < Base
      attribute :mode, Types::Strict::String.default("digest")
    end

    class Gcs < Base
      attribute :bucket, Types::Strict::String
      attribute :public_base, Types::Strict::String
      attribute :retention_episodes, Types::Strict::Integer
    end

    class Assets < Base
      attribute :bgm_path, Types::Strict::String
      attribute :cover_image, Types::Strict::String
      attribute :icon_image, Types::Strict::String
    end

    class Voicepeak < Base
      attribute :bin, Types::Strict::String
      # YAMLで秒数を整数(1, 10等)で書けるようにCoercible::Floatを使う。
      attribute :interval_sec, Types::Coercible::Float
      attribute :max_retries, Types::Strict::Integer
      attribute :retry_base_sec, Types::Coercible::Float
      attribute :timeout_sec, Types::Coercible::Float
      attribute :chunk_gap_sec, Types::Coercible::Float
    end

    class AiAgent < Base
      attribute :bin, Types::Strict::String
      attribute :model, Types::Strict::String
      # run_ai_cli が bin == "claude" のときだけ参照する。他の bin では
      # 書かれていても無視されるため任意属性にする。
      attribute? :effort, Types::Strict::String
      attribute? :selector_model, Types::Strict::String
      attribute? :extractor_model, Types::Strict::String
      attribute? :writer_model, Types::Strict::String
      attribute? :formatter_model, Types::Strict::String

      # role別モデルが未指定なら model にフォールバックする
      # （config.sample.yaml の ai_agent セクションのコメント参照）。
      def model_for(role)
        public_send(:"#{role}_model") || model
      end
    end

    class Category < Base
      attribute :label, Types::Strict::String
      attribute :description, Types::Strict::String
    end

    class ProgramDetails < Base
      attribute :total_news_count, Types::Strict::Integer
      attribute :categories, Types::Strict::Array.of(Category)
    end

    class Collect < Base
      attribute :lookback_hours, Types::Strict::Integer
      attribute :retention_days, Types::Strict::Integer
      attribute :fetch_threads, Types::Strict::Integer
      attribute :fetch_max_retries, Types::Strict::Integer
      attribute :fetch_retry_base_sec, Types::Coercible::Float
    end

    class RssFeedSource < Base
      Priority = Types::Strict::String.enum("high", "low")

      attribute :name, Types::Strict::String
      attribute? :url, Types::Strict::String
      attribute? :urls, Types::Strict::Array.of(Types::Strict::String)
      attribute? :priority, Priority

      # url/urls はどちらか一方のみを持つ（複数フィードを1ソース扱いしたい場合は
      # urls を使う）。型のSumでは「キーの有無の排他」を表現できないため、
      # 構築後に検証する。
      def initialize(*)
        super
        return if url.nil? ^ urls.nil?

        raise Dry::Struct::Error, "rss_feed_sources: #{name} は url または urls のどちらか一方のみを指定する"
      end
    end

    class Mixer < Base
      attribute :bgm_volume, Types::Coercible::Float
      attribute? :voice_boost_db, Types::Coercible::Float.default(0.0)
      attribute :intro_sec, Types::Coercible::Float
      attribute :tail_sec, Types::Coercible::Float
      attribute :fade_sec, Types::Coercible::Float
    end

    # config.yaml 全体を表す構造体。mode によってセクションの要否が変わるため、
    # 全セクションを任意属性にして常に構築を成功させ、mode別の必須チェックは
    # Config.validate_for! が構築後に行う（セクションの要否は運用ルールであり、
    # 型システムの責務ではないため）。
    class AppConfig < Base
      attribute(:pipeline, Pipeline.default { Pipeline.new({}) })
      attribute? :gcs, Gcs
      attribute? :assets, Assets
      attribute? :voicepeak, Voicepeak
      attribute? :ai_agent, AiAgent
      attribute? :program_details, ProgramDetails
      attribute? :collect, Collect
      attribute? :rss_feed_sources, Types::Strict::Array.of(RssFeedSource)
      attribute? :mixer, Mixer
    end
  end
end
