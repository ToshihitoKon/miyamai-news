# frozen_string_literal: true

require_relative "../facts_full_text"

module Internal
  module Notifiers
    # Pipeline#run_digest_only が facts ファイル生成直後に呼ぶ唯一の入口。
    # facts不在・config欠落時の warn-and-skip をここに集約する（詳細は
    # CLAUDE.md「Notifier」参照）。dispatch_slack/dispatch_discord の実装は
    # それぞれ PR3/PR4 で追加する。
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

      # PR3で実クライアント呼び出しに差し替える。
      def dispatch_slack(_parsed, raw_text:, episode_label:)
        warn "slack notify not implemented yet"
      end

      # PR4で実クライアント呼び出しに差し替える。
      def dispatch_discord(_parsed, raw_text:, episode_label:)
        warn "discord notify not implemented yet"
      end
    end
  end
end
