# frozen_string_literal: true

require "spec_helper"
require "internal/notifiers/slack_notifier"
require "internal/facts_full_text"

RSpec.describe Internal::Notifiers::SlackNotifier do
  let(:notifier) { described_class.new(bot_token: "xoxb-x", channel: "C1") }
  let(:fake_client) { instance_double(Internal::Notifiers::SlackClient) }

  before { allow(Internal::Notifiers::SlackClient).to receive(:new).and_return(fake_client) }

  let(:parsed_text) do
    <<~TEXT
      ## 生成AI

      ### [メイン] Title A
      - **URL**: https://example.com/a
      - **要点・要約**:
        - 説明A
    TEXT
  end

  describe "#notify" do
    context "パース成功時" do
      it "親メッセージを投稿し、その ts を thread_ts に指定してカテゴリごとにスレッド返信する" do
        parent_response = instance_double(Internal::Notifiers::SlackClient::Response, ok: true, ts: "100.1", error: nil)
        thread_response = instance_double(Internal::Notifiers::SlackClient::Response, ok: true, ts: nil, error: nil)
        allow(fake_client).to receive(:post_message).and_return(parent_response, thread_response)

        parsed = Internal::FactsFullText.parse(parsed_text)
        notifier.notify(parsed, raw_text: parsed_text, episode_label: "label")

        expect(fake_client).to have_received(:post_message).with(hash_excluding(:thread_ts)).once
        expect(fake_client).to have_received(:post_message).with(hash_including(channel: "C1", thread_ts: "100.1")).once
      end

      it "親メッセージの投稿が失敗したらスレッド返信を一切行わない" do
        parent_response = instance_double(Internal::Notifiers::SlackClient::Response, ok: false, ts: nil, error: "channel_not_found")
        allow(fake_client).to receive(:post_message).and_return(parent_response)

        parsed = Internal::FactsFullText.parse(parsed_text)
        notifier.notify(parsed, raw_text: parsed_text, episode_label: "label")

        expect(fake_client).to have_received(:post_message).once
      end

      it "1つのスレッド返信が失敗しても後続のカテゴリ投稿を継続する" do
        text = <<~TEXT
          ## カテゴリ1

          ### [メイン] Title A
          - **要点**: A

          ## カテゴリ2

          ### [メイン] Title B
          - **要点**: B
        TEXT
        parent_response = instance_double(Internal::Notifiers::SlackClient::Response, ok: true, ts: "100.1", error: nil)
        failed_thread = instance_double(Internal::Notifiers::SlackClient::Response, ok: false, ts: nil, error: "rate_limited")
        ok_thread = instance_double(Internal::Notifiers::SlackClient::Response, ok: true, ts: nil, error: nil)
        allow(fake_client).to receive(:post_message).and_return(parent_response, failed_thread, ok_thread)

        parsed = Internal::FactsFullText.parse(text)
        notifier.notify(parsed, raw_text: text, episode_label: "label")

        expect(fake_client).to have_received(:post_message).exactly(3).times
      end

      it "カテゴリ全文が MESSAGE_LIMIT を超える場合は複数チャンクに分割して同じ thread_ts へ送る" do
        long_body = "説明" * 3000
        text = <<~TEXT
          ## 生成AI

          ### [メイン] Title A
          - **要点・要約**:
            - #{long_body}
        TEXT
        parent_response = instance_double(Internal::Notifiers::SlackClient::Response, ok: true, ts: "100.1", error: nil)
        thread_response = instance_double(Internal::Notifiers::SlackClient::Response, ok: true, ts: nil, error: nil)
        allow(fake_client).to receive(:post_message).and_return(parent_response, thread_response, thread_response, thread_response)

        parsed = Internal::FactsFullText.parse(text)
        notifier.notify(parsed, raw_text: text, episode_label: "label")

        expect(fake_client).to have_received(:post_message).with(hash_including(thread_ts: "100.1")).at_least(:twice)
      end
    end

    context "パース失敗時" do
      it "生テキストをチャンク分割してスレッド返信する（notify_raw フォールバック）" do
        broken_text = "壊れたフォーマット"
        parent_response = instance_double(Internal::Notifiers::SlackClient::Response, ok: true, ts: "100.1", error: nil)
        thread_response = instance_double(Internal::Notifiers::SlackClient::Response, ok: true, ts: nil, error: nil)
        allow(fake_client).to receive(:post_message).and_return(parent_response, thread_response)
        allow(notifier).to receive(:warn)

        parsed = Internal::FactsFullText.parse(broken_text)
        notifier.notify(parsed, raw_text: broken_text, episode_label: "label")

        expect(fake_client).to have_received(:post_message).with(hash_including(text: a_string_including(broken_text), thread_ts: "100.1"))
      end
    end
  end
end
