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

    # *_sec 系(interval_sec/retry_base_sec/timeout_sec/chunk_gap_sec/mid_pause_sec/
    # long_pause_sec)は Coercible::Float。YAML に "1" のような整数表記のままでも
    # 通せるようにするため。
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
      # 現状 bin == "claude" のときだけ run_ai_cli が参照する。将来 effort に対応する
      # 別の AI CLI が増えたときのために任意属性にしている。
      attribute? :effort, Types::Strict::String
      attribute? :selector_model, Types::Strict::String
      attribute? :extractor_model, Types::Strict::String
      attribute? :writer_model, Types::Strict::String
      attribute? :formatter_model, Types::Strict::String
      # used_news のフォーマット修復専用。パース失敗時のみ呼ばれる軽量モデル。
      # effort は bin == "claude" のとき run_ai_cli の effort_override に渡す。
      attribute? :used_fix_model, Types::Strict::String
      attribute? :used_fix_effort, Types::Strict::String
      # フォーマット修復の最大リトライ回数。0 で修復自体を無効化する
      # （UsedNewsFormatter.repair は Integer#times で回すため、0 なら AI を
      # 一度も呼ばずに諦める）。
      attribute? :used_fix_max_retries, Types::Strict::Integer.default(2)

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
      # 各フィードの最終 fetch からこの分数以内は、再取得せず前回キャッシュから返す。
      # 0 でスキップ無効（常に fetch）。
      attribute? :fetch_skip_minutes, Types::Strict::Integer.default(5)
      # 直近この回数分の紹介済みニュースを selector に渡し、回またぎの重複紹介を避ける
      # （詳細は CLAUDE.md 参照）。
      attribute? :used_news_history_episodes, Types::Strict::Integer.default(4)
    end

    # 1 ソース = 1 フィード URL = 1 キャッシュファイルの 1:1 対応を保つ。同じ記事が
    # 複数フィードから流れてくる重複は FeedCache の関心事ではなく、収集後の
    # dedup_by_title が扱う（CLAUDE.md 参照）。
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

    # Slack Web API (chat.postMessage) の認証情報。incoming webhook ではなく
    # bot_token + channel を使う理由は CLAUDE.md「Notifier」参照（スレッド返信に
    # thread_ts の指定が必要なため）。
    class SlackNotify < Base
      attribute :bot_token, Types::Strict::String
      attribute :channel, Types::Strict::String
    end

    # Discord webhook の認証情報。認証ヘッダーは不要で webhook URL 自体が秘匿情報
    # （詳細は CLAUDE.md「Notifier」参照）。
    class DiscordNotify < Base
      attribute :webhook_url, Types::Strict::String
    end

    # Slack/Discord への digest 全文通知（任意機能。詳細は CLAUDE.md「Notifier」参照）。
    # 配信先の切り替えは CLI フラグを持たず、この targets のみで行う
    # （--digest-only 実行時、列挙された配信先だけが自動的に通知される）。
    class Notify < Base
      attribute? :targets, Types::Strict::Array.of(Types::Strict::String).default([].freeze)
      attribute? :slack, SlackNotify
      attribute? :discord, DiscordNotify
    end

    # config.yaml 全体を表す構造体。mode によってセクションの要否が変わるため、
    # 全セクションを任意属性にする（必須判定は Config.validate_for! が行う）。
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
      attribute? :notify, Notify
    end
  end
end
