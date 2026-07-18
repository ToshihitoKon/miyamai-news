# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "internal/last_fetch_store"

RSpec.describe LastFetchStore do
  let(:work_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(work_dir) }

  describe ".mark_pending!" do
    it "sets pending_at without moving confirmed_at" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      pending = Time.utc(2026, 7, 16, 9, 0, 0)
      described_class.confirm_immediately!(work_dir: work_dir, at: confirmed)

      described_class.mark_pending!(work_dir: work_dir, at: pending)

      expect(described_class.confirmed_at(work_dir)).to eq(confirmed)
      expect(described_class.pending_at(work_dir)).to eq(pending)
    end

    # 自動的な pending 化は人間の操作ではないので Undo 対象にしない。
    it "is not restorable (clears the undo buffer)" do
      described_class.mark_pending!(work_dir: work_dir, at: Time.utc(2026, 7, 15, 9, 0, 0))
      described_class.rollback!(work_dir: work_dir)

      described_class.mark_pending!(work_dir: work_dir, at: Time.utc(2026, 7, 16, 9, 0, 0))

      expect(described_class.restorable?(work_dir)).to be false
    end

    it "works from an empty store (no prior confirmed_at)" do
      pending = Time.utc(2026, 7, 16, 9, 0, 0)

      described_class.mark_pending!(work_dir: work_dir, at: pending)

      expect(described_class.confirmed_at(work_dir)).to be_nil
      expect(described_class.pending_at(work_dir)).to eq(pending)
    end
  end

  describe ".confirm!" do
    it "promotes pending_at to confirmed_at" do
      described_class.confirm_immediately!(work_dir: work_dir, at: Time.utc(2026, 7, 14, 9, 0, 0))
      pending = Time.utc(2026, 7, 16, 9, 0, 0)
      described_class.mark_pending!(work_dir: work_dir, at: pending)

      described_class.confirm!(work_dir: work_dir)

      expect(described_class.confirmed_at(work_dir)).to eq(pending)
      expect(described_class.pending_at(work_dir)).to be_nil
    end

    it "becomes restorable so an accidental confirm can be undone" do
      described_class.confirm_immediately!(work_dir: work_dir, at: Time.utc(2026, 7, 14, 9, 0, 0))
      described_class.mark_pending!(work_dir: work_dir, at: Time.utc(2026, 7, 16, 9, 0, 0))

      described_class.confirm!(work_dir: work_dir)

      expect(described_class.restorable?(work_dir)).to be true
    end

    it "does nothing when there is no pending_at" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      described_class.confirm_immediately!(work_dir: work_dir, at: confirmed)

      described_class.confirm!(work_dir: work_dir)

      expect(described_class.confirmed_at(work_dir)).to eq(confirmed)
      expect(described_class.restorable?(work_dir)).to be false
    end
  end

  describe ".rollback!" do
    it "keeps confirmed_at unchanged and clears pending_at" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      described_class.confirm_immediately!(work_dir: work_dir, at: confirmed)
      described_class.mark_pending!(work_dir: work_dir, at: Time.utc(2026, 7, 16, 9, 0, 0))

      described_class.rollback!(work_dir: work_dir)

      expect(described_class.confirmed_at(work_dir)).to eq(confirmed)
      expect(described_class.pending_at(work_dir)).to be_nil
    end

    it "becomes restorable so an accidental rollback can be undone" do
      described_class.confirm_immediately!(work_dir: work_dir, at: Time.utc(2026, 7, 14, 9, 0, 0))
      described_class.mark_pending!(work_dir: work_dir, at: Time.utc(2026, 7, 16, 9, 0, 0))

      described_class.rollback!(work_dir: work_dir)

      expect(described_class.restorable?(work_dir)).to be true
    end

    it "does nothing when there is no pending_at" do
      described_class.rollback!(work_dir: work_dir)

      expect(described_class.restorable?(work_dir)).to be false
    end
  end

  describe ".restore!" do
    # confirm の取り消し: 昇格した confirmed を pending へ戻し、元の confirmed を戻す。
    it "undoes a confirm, restoring both pending_at and the old confirmed_at" do
      old_confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      pending = Time.utc(2026, 7, 16, 9, 0, 0)
      described_class.confirm_immediately!(work_dir: work_dir, at: old_confirmed)
      described_class.mark_pending!(work_dir: work_dir, at: pending)
      described_class.confirm!(work_dir: work_dir)

      described_class.restore!(work_dir: work_dir)

      expect(described_class.pending_at(work_dir)).to eq(pending)
      expect(described_class.confirmed_at(work_dir)).to eq(old_confirmed)
      expect(described_class.restorable?(work_dir)).to be false
    end

    # discard の取り消し: 捨てた pending を戻すだけ。confirmed は動かさない。
    it "undoes a rollback, restoring only the discarded pending_at" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      pending = Time.utc(2026, 7, 16, 9, 0, 0)
      described_class.confirm_immediately!(work_dir: work_dir, at: confirmed)
      described_class.mark_pending!(work_dir: work_dir, at: pending)
      described_class.rollback!(work_dir: work_dir)

      described_class.restore!(work_dir: work_dir)

      expect(described_class.pending_at(work_dir)).to eq(pending)
      expect(described_class.confirmed_at(work_dir)).to eq(confirmed)
      expect(described_class.restorable?(work_dir)).to be false
    end

    it "does nothing when there is nothing to restore" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      described_class.confirm_immediately!(work_dir: work_dir, at: confirmed)

      described_class.restore!(work_dir: work_dir)

      expect(described_class.pending_at(work_dir)).to be_nil
      expect(described_class.confirmed_at(work_dir)).to eq(confirmed)
    end
  end

  describe ".confirm_immediately!" do
    it "sets confirmed_at regardless of any pending state" do
      described_class.mark_pending!(work_dir: work_dir, at: Time.utc(2026, 7, 14, 9, 0, 0))
      published_at = Time.utc(2026, 7, 16, 9, 0, 0)

      described_class.confirm_immediately!(work_dir: work_dir, at: published_at)

      expect(described_class.confirmed_at(work_dir)).to eq(published_at)
      expect(described_class.pending_at(work_dir)).to be_nil
    end

    # publish 時の即時確定は人間の対話操作ではないので Undo 対象にしない。
    it "is not restorable (clears the undo buffer)" do
      described_class.mark_pending!(work_dir: work_dir, at: Time.utc(2026, 7, 14, 9, 0, 0))
      described_class.rollback!(work_dir: work_dir)

      described_class.confirm_immediately!(work_dir: work_dir, at: Time.utc(2026, 7, 16, 9, 0, 0))

      expect(described_class.restorable?(work_dir)).to be false
    end
  end

  describe ".resolve_pending!" do
    let(:confirmed) { Time.utc(2026, 7, 14, 9, 0, 0) }
    let(:pending) { Time.utc(2026, 7, 16, 9, 0, 0) }

    before do
      described_class.confirm_immediately!(work_dir: work_dir, at: confirmed)
      described_class.mark_pending!(work_dir: work_dir, at: pending)
      # 対話の出力はテストログに混ぜない。
      allow(described_class).to receive(:warn)
      allow(described_class).to receive(:print)
    end

    it "auto-confirms without prompting when auto_confirm is true" do
      expect($stdin).not_to receive(:gets)

      described_class.resolve_pending!(work_dir: work_dir, auto_confirm: true)

      expect(described_class.confirmed_at(work_dir)).to eq(pending)
      expect(described_class.pending_at(work_dir)).to be_nil
    end

    it "confirms when the user answers yes" do
      allow($stdin).to receive(:gets).and_return("y\n")

      described_class.resolve_pending!(work_dir: work_dir)

      expect(described_class.confirmed_at(work_dir)).to eq(pending)
    end

    it "rolls back when the user answers no (the safe default)" do
      allow($stdin).to receive(:gets).and_return("\n")

      described_class.resolve_pending!(work_dir: work_dir)

      expect(described_class.confirmed_at(work_dir)).to eq(confirmed)
      expect(described_class.pending_at(work_dir)).to be_nil
    end

    it "does nothing when there is no pending" do
      described_class.confirm!(work_dir: work_dir) # pending を消しておく
      expect($stdin).not_to receive(:gets)

      described_class.resolve_pending!(work_dir: work_dir)

      expect(described_class.confirmed_at(work_dir)).to eq(pending)
    end
  end

  describe ".confirmed_at / .pending_at" do
    it "returns nil when the store is empty" do
      expect(described_class.confirmed_at(work_dir)).to be_nil
      expect(described_class.pending_at(work_dir)).to be_nil
    end

    it "returns nil when the stored timestamp is corrupt" do
      FileUtils.mkdir_p(work_dir)
      File.write(described_class.path(work_dir), JSON.generate("confirmed_at" => "not-a-timestamp", "pending_at" => nil, "rollback_at" => nil))

      expect(described_class.confirmed_at(work_dir)).to be_nil
    end
  end

  describe ".load (migration)" do
    it "returns all-nil defaults when neither last_fetch.json nor the legacy file exists" do
      expect(described_class.load(work_dir)).to eq("confirmed_at" => nil, "pending_at" => nil, "rollback_at" => nil, "last_op" => nil)
    end

    # last_op 導入前に書かれた新形式ファイルには last_op キーが無い。読み込み時に補う。
    it "fills in last_op for a pre-last_op new-format file" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      File.write(described_class.path(work_dir), JSON.generate("confirmed_at" => confirmed.iso8601, "pending_at" => nil, "rollback_at" => nil))

      data = described_class.load(work_dir)

      expect(data["confirmed_at"]).to eq(confirmed.iso8601)
      expect(data).to have_key("last_op")
      expect(data["last_op"]).to be_nil
    end

    it "migrates a legacy mode-keyed last_fetch.json (publish present) into confirmed_at" do
      digest_at = Time.utc(2026, 7, 10, 8, 0, 0)
      publish_at = Time.utc(2026, 7, 12, 8, 0, 0)
      File.write(described_class.path(work_dir), JSON.generate("digest" => digest_at.iso8601, "publish" => publish_at.iso8601))

      data = described_class.load(work_dir)

      expect(data["confirmed_at"]).to eq(publish_at.iso8601)
      expect(data["pending_at"]).to be_nil
      expect(data["rollback_at"]).to be_nil
    end

    it "migrates a legacy mode-keyed last_fetch.json (digest only) into confirmed_at" do
      digest_at = Time.utc(2026, 7, 10, 8, 0, 0)
      File.write(described_class.path(work_dir), JSON.generate("digest" => digest_at.iso8601))

      data = described_class.load(work_dir)

      expect(data["confirmed_at"]).to eq(digest_at.iso8601)
    end

    it "migrates the legacy last_fetch.txt into confirmed_at" do
      at = Time.utc(2026, 7, 10, 8, 0, 0)
      File.write(described_class.legacy_path(work_dir), at.iso8601)

      data = described_class.load(work_dir)

      expect(data["confirmed_at"]).to eq(at.iso8601)
      expect(File.exist?(described_class.legacy_path(work_dir))).to be false
      expect(File.exist?(described_class.path(work_dir))).to be true
    end

    it "leaves a corrupt legacy last_fetch.txt untouched and returns defaults" do
      File.write(described_class.legacy_path(work_dir), "not-a-timestamp")

      expect(described_class.load(work_dir)).to eq("confirmed_at" => nil, "pending_at" => nil, "rollback_at" => nil, "last_op" => nil)
      expect(File.exist?(described_class.legacy_path(work_dir))).to be true
    end

    it "leaves a corrupt last_fetch.json untouched and returns defaults" do
      FileUtils.mkdir_p(work_dir)
      File.write(described_class.path(work_dir), "not-json")

      expect(described_class.load(work_dir)).to eq("confirmed_at" => nil, "pending_at" => nil, "rollback_at" => nil, "last_op" => nil)
      expect(File.read(described_class.path(work_dir))).to eq("not-json")
    end
  end
end
