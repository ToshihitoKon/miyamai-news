# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "internal/notifiers/notify_dispatcher"

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

    it "slack/discord ともに未実装として warn する（PR2時点の骨格）" do
      File.write(facts_path, "## cat\n### [メイン] title\n")

      described_class.run(%w[slack discord], facts_path: facts_path, episode_label: "label")

      expect(described_class).to have_received(:warn).with(a_string_matching(/slack notify not implemented yet/))
      expect(described_class).to have_received(:warn).with(a_string_matching(/discord notify not implemented yet/))
    end

    it "1ターゲットが例外を投げても他ターゲットの処理を継続する" do
      File.write(facts_path, "## cat\n### [メイン] title\n")
      allow(described_class).to receive(:dispatch_slack).and_raise(StandardError, "boom")

      described_class.run(%w[slack discord], facts_path: facts_path, episode_label: "label")

      expect(described_class).to have_received(:warn).with(a_string_matching(/notify to slack failed unexpectedly: boom/))
      expect(described_class).to have_received(:warn).with(a_string_matching(/discord notify not implemented yet/))
    end
  end
end
