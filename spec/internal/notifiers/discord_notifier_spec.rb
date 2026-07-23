# frozen_string_literal: true

require "spec_helper"
require "internal/notifiers/discord_notifier"
require "internal/facts_full_text"

RSpec.describe Internal::Notifiers::DiscordNotifier do
  let(:notifier) { described_class.new(webhook_url: "https://discord.example/webhook") }
  let(:fake_client) { instance_double(Internal::Notifiers::DiscordClient) }

  before do
    allow(Internal::Notifiers::DiscordClient).to receive(:new).and_return(fake_client)
    allow(notifier).to receive(:warn)
  end

  describe "#notify" do
    context "パース成功時" do
      it "各カテゴリ・記事の全文を含むメッセージを投稿する" do
        text = <<~TEXT
          ## 生成AI

          ### [メイン] Title A
          - **URL**: https://example.com/a
          - **要点・要約**:
            - 説明A
        TEXT
        allow(fake_client).to receive(:post_message).and_return(true)

        parsed = Internal::FactsFullText.parse(text)
        notifier.notify(parsed, raw_text: text, episode_label: "label")

        expect(fake_client).to have_received(:post_message) do |content:|
          expect(content).to include("Title A", "生成AI", "label")
        end
      end

      it "全メッセージが 2000 文字（CONTENT_LIMIT）以内に収まる" do
        long_body = "説明" * 3000
        text = <<~TEXT
          ## 生成AI

          ### [メイン] Title A
          - **要点・要約**:
            - #{long_body}
        TEXT
        allow(fake_client).to receive(:post_message).and_return(true)

        parsed = Internal::FactsFullText.parse(text)
        notifier.notify(parsed, raw_text: text, episode_label: "label")

        expect(fake_client).to have_received(:post_message).at_least(:twice) do |content:|
          expect(content.length).to be <= 2000
        end
      end

      it "1通の投稿が失敗しても残りのチャンクの投稿を継続する" do
        long_body = "説明" * 3000
        text = <<~TEXT
          ## カテゴリ1

          ### [メイン] Title A
          - **要点・要約**:
            - #{long_body}

          ## カテゴリ2

          ### [メイン] Title B
          - **要点**: B
        TEXT
        call_count = 0
        allow(fake_client).to receive(:post_message) do
          call_count += 1
          call_count != 1
        end

        parsed = Internal::FactsFullText.parse(text)
        notifier.notify(parsed, raw_text: text, episode_label: "label")

        expect(call_count).to be >= 2
      end
    end

    context "パース失敗時" do
      it "生テキストをチャンク分割して投稿する（フォールバック）" do
        broken_text = "壊れたフォーマット"
        allow(fake_client).to receive(:post_message).and_return(true)

        parsed = Internal::FactsFullText.parse(broken_text)
        notifier.notify(parsed, raw_text: broken_text, episode_label: "label")

        expect(fake_client).to have_received(:post_message).with(content: a_string_including(broken_text))
      end
    end
  end
end
