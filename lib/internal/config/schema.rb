# frozen_string_literal: true

require "dry-struct"
require_relative "types"

module Internal
  module Config
    class Base < Dry::Struct
      transform_keys(&:to_sym)
    end

    class Pipeline < Base
      attribute :mode, Types::Strict::String.default("digest")
    end

    class Cloudflare < Base
      attribute :account_id, Types::Strict::String
      attribute :worker_name, Types::Strict::String
      attribute :bucket, Types::Strict::String
      attribute :public_base, Types::Strict::String
      attribute :retention_episodes, Types::Strict::Integer
      attribute? :episode_prefix, Types::Strict::String.default("episodes")
    end

    class Assets < Base
      attribute :bgm_path, Types::Strict::String
      attribute :cover_image, Types::Strict::String
      attribute :icon_image, Types::Strict::String
    end

    class Voicepeak < Base
      attribute :bin, Types::Strict::String
      attribute :interval_sec, Types::Coercible::Float
      attribute :max_retries, Types::Strict::Integer
      attribute :retry_base_sec, Types::Coercible::Float
      attribute :timeout_sec, Types::Coercible::Float
      attribute :chunk_gap_sec, Types::Coercible::Float
      attribute :mid_pause_sec, Types::Coercible::Float
      attribute :long_pause_sec, Types::Coercible::Float
    end

    class AiAgent < Base
      attribute :bin, Types::Strict::String
      attribute :model, Types::Strict::String
      attribute? :effort, Types::Strict::String
      attribute? :selector_model, Types::Strict::String
      attribute? :extractor_model, Types::Strict::String
      attribute? :writer_model, Types::Strict::String
      attribute? :formatter_model, Types::Strict::String
      # used_news のフォーマット修復専用モデル。
      attribute? :used_fix_model, Types::Strict::String
      attribute? :used_fix_effort, Types::Strict::String
      # フォーマット修復の最大リトライ回数。
      attribute? :used_fix_max_retries, Types::Strict::Integer.default(2)

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
      # 各フィードの最終 fetch からこの分数以内は、再取得せず前回キャッシュから返す。
      # 0 でスキップ無効。
      attribute? :fetch_skip_minutes, Types::Strict::Integer.default(5)
      # 直近この回数分の紹介済みニュースを selector に渡す。
      attribute? :used_news_history_episodes, Types::Strict::Integer.default(4)
    end

    class RssFeedSource < Base
      Priority = Types::Strict::String.enum("high", "low")

      attribute :name, Types::Strict::String
      attribute :url, Types::Strict::String
      attribute? :priority, Priority
    end

    class Mixer < Base
      attribute :bgm_volume, Types::Coercible::Float
      attribute? :voice_boost_db, Types::Coercible::Float.default(0.0)
      attribute :intro_sec, Types::Coercible::Float
      attribute :tail_sec, Types::Coercible::Float
      attribute :fade_sec, Types::Coercible::Float
    end

    class WebPush < Base
      attribute :vapid_public_key, Types::Strict::String
    end

    # config.yaml 全体を表す構造体。必須判定は Config.validate_for! が行う。
    class AppConfig < Base
      attribute(:pipeline, Pipeline.default { Pipeline.new({}) })
      attribute? :cloudflare, Cloudflare
      attribute? :assets, Assets
      attribute? :voicepeak, Voicepeak
      attribute? :ai_agent, AiAgent
      attribute? :program_details, ProgramDetails
      attribute? :collect, Collect
      attribute? :rss_feed_sources, Types::Strict::Array.of(RssFeedSource)
      attribute? :mixer, Mixer
      attribute? :web_push, WebPush
    end
  end
end
