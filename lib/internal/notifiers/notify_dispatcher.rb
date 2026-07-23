# frozen_string_literal: true

require_relative "../config"
require_relative "../facts_full_text"
require_relative "slack_notifier"

module Internal
  module Notifiers
    # Pipeline#run_digest_only が facts ファイル生成直後に呼ぶ唯一の入口。
    # facts不在・config欠落時の warn-and-skip をここに集約する（詳細は
    # CLAUDE.md「Notifier」参照）。dispatch_discord の実装は後続 PR で追加する。
    module NotifyDispatcher
      module_function

      # targets: Config.notify.targets（例: ["slack", "discord"]）。
      def run(targets, facts_path:, episode_label:)
        return if targets.nil? || targets.empty?

        unless File.exist?(facts_path)
          warn "facts file not found, skipping notify: #{facts_path}"
          return
        end

        raw_text = File.read(facts_path)
        parsed = Internal::FactsFullText.parse(raw_text)

        targets.each do |target|
          case target
          when "slack" then dispatch_slack(parsed, raw_text: raw_text, episode_label: episode_label)
          when "discord" then dispatch_discord(parsed, raw_text: raw_text, episode_label: episode_label)
          else warn "unknown notify target: #{target}"
          end
        rescue StandardError => e
          # 1ターゲットの想定外クラッシュが他ターゲットの投稿を道連れにしないための防御。
          warn "notify to #{target} failed unexpectedly: #{e.message}"
        end
      end

      def dispatch_slack(parsed, raw_text:, episode_label:)
        # Internal::Notifiers 内で単に Config と書くと、Ruby の定数解決順序により
        # Internal::Config（schema.rb の型定義モジュール）が先に見つかってしまう
        # （トップレベルの Config ローダーとは別物）。::Config で明示する。
        cfg = ::Config.notify&.slack
        return warn "slack notify requested but config.notify.slack is missing, skipping" unless cfg

        SlackNotifier.new(bot_token: cfg.bot_token, channel: cfg.channel)
                     .notify(parsed, raw_text: raw_text, episode_label: episode_label)
      end

      # 後続 PR で実クライアント呼び出しに差し替える。
      def dispatch_discord(_parsed, raw_text:, episode_label:)
        warn "discord notify not implemented yet"
      end
    end
  end
end
