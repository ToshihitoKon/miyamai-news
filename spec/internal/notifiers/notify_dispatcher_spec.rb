# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "internal/config"
require "internal/notifiers/notify_dispatcher"
require "internal/notifiers/slack_notifier"
require "internal/notifiers/discord_notifier"

RSpec.describe Internal::Notifiers::NotifyDispatcher do
  let(:work_dir) { Dir.mktmpdir }
  let(:facts_path) { File.join(work_dir, "news_facts_20260714_afternoon.txt") }

  after { FileUtils.remove_entry(work_dir) }

  before { allow(described_class).to receive(:warn) }

  describe ".run" do
    it "targets が空なら何もしない" do
      described_class.run([], facts_path: facts_path, episode_label: "label")

      expect(described_class).not_to have_received(:warn)
    end

    it "targets が nil なら何もしない" do
      described_class.run(nil, facts_path: facts_path, episode_label: "label")

      expect(described_class).not_to have_received(:warn)
    end

    it "facts ファイルが存在しなければ warn してスキップする" do
      described_class.run(["slack"], facts_path: facts_path, episode_label: "label")

      expect(described_class).to have_received(:warn).with(a_string_matching(/facts file not found/))
    end

    it "不明な target は warn する" do
      File.write(facts_path, "## cat\n### [メイン] title\n")

      described_class.run(["mastodon"], facts_path: facts_path, episode_label: "label")

      expect(described_class).to have_received(:warn).with(a_string_matching(/unknown notify target: mastodon/))
    end

    it "config.notify.discord が未設定なら discord を warn してスキップする" do
      File.write(facts_path, "## cat\n### [メイン] title\n")
      allow(Config).to receive(:notify).and_return(nil)

      described_class.run(["discord"], facts_path: facts_path, episode_label: "label")

      expect(described_class).to have_received(:warn).with(a_string_matching(/config.notify.discord is missing/))
    end

    it "config.notify.discord があれば DiscordNotifier#notify を呼ぶ" do
      File.write(facts_path, "## cat\n### [メイン] title\n")
      discord_cfg = instance_double(Internal::Config::DiscordNotify, webhook_url: "https://discord.example/webhook")
      allow(Config).to receive(:notify).and_return(instance_double(Internal::Config::Notify, discord: discord_cfg))
      fake_notifier = instance_double(Internal::Notifiers::DiscordNotifier, notify: nil)
      allow(Internal::Notifiers::DiscordNotifier).to receive(:new).with(webhook_url: "https://discord.example/webhook").and_return(fake_notifier)

      described_class.run(["discord"], facts_path: facts_path, episode_label: "label")

      expect(fake_notifier).to have_received(:notify).with(
        an_instance_of(Internal::FactsFullText::Result), raw_text: "## cat\n### [メイン] title\n", episode_label: "label"
      )
    end

    it "config.notify.slack が未設定なら slack を warn してスキップする" do
      File.write(facts_path, "## cat\n### [メイン] title\n")
      allow(Config).to receive(:notify).and_return(nil)

      described_class.run(["slack"], facts_path: facts_path, episode_label: "label")

      expect(described_class).to have_received(:warn).with(a_string_matching(/config.notify.slack is missing/))
    end

    it "config.notify.slack があれば SlackNotifier#notify を呼ぶ" do
      File.write(facts_path, "## cat\n### [メイン] title\n")
      slack_cfg = instance_double(Internal::Config::SlackNotify, bot_token: "xoxb-x", channel: "C1")
      allow(Config).to receive(:notify).and_return(instance_double(Internal::Config::Notify, slack: slack_cfg))
      fake_notifier = instance_double(Internal::Notifiers::SlackNotifier, notify: nil)
      allow(Internal::Notifiers::SlackNotifier).to receive(:new).with(bot_token: "xoxb-x", channel: "C1").and_return(fake_notifier)

      described_class.run(["slack"], facts_path: facts_path, episode_label: "label")

      expect(fake_notifier).to have_received(:notify).with(
        an_instance_of(Internal::FactsFullText::Result), raw_text: "## cat\n### [メイン] title\n", episode_label: "label"
      )
    end

    it "1ターゲットが例外を投げても他ターゲットの処理を継続する" do
      File.write(facts_path, "## cat\n### [メイン] title\n")
      allow(Config).to receive(:notify).and_return(nil)
      allow(described_class).to receive(:dispatch_slack).and_raise(StandardError, "boom")

      described_class.run(%w[slack discord], facts_path: facts_path, episode_label: "label")

      expect(described_class).to have_received(:warn).with(a_string_matching(/notify to slack failed unexpectedly: boom/))
      expect(described_class).to have_received(:warn).with(a_string_matching(/config.notify.discord is missing/))
    end
  end
end
