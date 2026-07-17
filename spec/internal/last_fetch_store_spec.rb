# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "internal/last_fetch_store"

RSpec.describe LastFetchStore do
  let(:work_dir) { Dir.mktmpdir }
  let(:store) { described_class.new(work_dir: work_dir) }

  after { FileUtils.remove_entry(work_dir) }

  describe "#mark_pending!" do
    it "sets pending_at without moving confirmed_at" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      pending = Time.utc(2026, 7, 16, 9, 0, 0)
      store.confirm_immediately!(at: confirmed)

      store.mark_pending!(at: pending)

      expect(store.confirmed_at).to eq(confirmed)
      expect(store.pending_at).to eq(pending)
    end

    # 自動的な pending 化は人間の操作ではないので Undo 対象にしない。
    it "is not restorable (clears the undo buffer)" do
      store.mark_pending!(at: Time.utc(2026, 7, 15, 9, 0, 0))
      store.rollback!

      store.mark_pending!(at: Time.utc(2026, 7, 16, 9, 0, 0))

      expect(store.restorable?).to be false
    end

    it "works from an empty store (no prior confirmed_at)" do
      pending = Time.utc(2026, 7, 16, 9, 0, 0)

      store.mark_pending!(at: pending)

      expect(store.confirmed_at).to be_nil
      expect(store.pending_at).to eq(pending)
    end
  end

  describe "#confirm!" do
    it "promotes pending_at to confirmed_at" do
      store.confirm_immediately!(at: Time.utc(2026, 7, 14, 9, 0, 0))
      pending = Time.utc(2026, 7, 16, 9, 0, 0)
      store.mark_pending!(at: pending)

      store.confirm!

      expect(store.confirmed_at).to eq(pending)
      expect(store.pending_at).to be_nil
    end

    it "becomes restorable so an accidental confirm can be undone" do
      store.confirm_immediately!(at: Time.utc(2026, 7, 14, 9, 0, 0))
      store.mark_pending!(at: Time.utc(2026, 7, 16, 9, 0, 0))

      store.confirm!

      expect(store.restorable?).to be true
    end

    it "does nothing when there is no pending_at" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      store.confirm_immediately!(at: confirmed)

      store.confirm!

      expect(store.confirmed_at).to eq(confirmed)
      expect(store.restorable?).to be false
    end
  end

  describe "#rollback!" do
    it "keeps confirmed_at unchanged and clears pending_at" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      store.confirm_immediately!(at: confirmed)
      store.mark_pending!(at: Time.utc(2026, 7, 16, 9, 0, 0))

      store.rollback!

      expect(store.confirmed_at).to eq(confirmed)
      expect(store.pending_at).to be_nil
    end

    it "becomes restorable so an accidental rollback can be undone" do
      store.confirm_immediately!(at: Time.utc(2026, 7, 14, 9, 0, 0))
      store.mark_pending!(at: Time.utc(2026, 7, 16, 9, 0, 0))

      store.rollback!

      expect(store.restorable?).to be true
    end

    it "does nothing when there is no pending_at" do
      store.rollback!

      expect(store.restorable?).to be false
    end
  end

  describe "#restore!" do
    # confirm の取り消し: 昇格した confirmed を pending へ戻し、元の confirmed を戻す。
    it "undoes a confirm, restoring both pending_at and the old confirmed_at" do
      old_confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      pending = Time.utc(2026, 7, 16, 9, 0, 0)
      store.confirm_immediately!(at: old_confirmed)
      store.mark_pending!(at: pending)
      store.confirm!

      store.restore!

      expect(store.pending_at).to eq(pending)
      expect(store.confirmed_at).to eq(old_confirmed)
      expect(store.restorable?).to be false
    end

    # discard の取り消し: 捨てた pending を戻すだけ。confirmed は動かさない。
    it "undoes a rollback, restoring only the discarded pending_at" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      pending = Time.utc(2026, 7, 16, 9, 0, 0)
      store.confirm_immediately!(at: confirmed)
      store.mark_pending!(at: pending)
      store.rollback!

      store.restore!

      expect(store.pending_at).to eq(pending)
      expect(store.confirmed_at).to eq(confirmed)
      expect(store.restorable?).to be false
    end

    it "does nothing when there is nothing to restore" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      store.confirm_immediately!(at: confirmed)

      store.restore!

      expect(store.pending_at).to be_nil
      expect(store.confirmed_at).to eq(confirmed)
    end
  end

  describe "#confirm_immediately!" do
    it "sets confirmed_at regardless of any pending state" do
      store.mark_pending!(at: Time.utc(2026, 7, 14, 9, 0, 0))
      published_at = Time.utc(2026, 7, 16, 9, 0, 0)

      store.confirm_immediately!(at: published_at)

      expect(store.confirmed_at).to eq(published_at)
      expect(store.pending_at).to be_nil
    end

    # publish 時の即時確定は人間の対話操作ではないので Undo 対象にしない。
    it "is not restorable (clears the undo buffer)" do
      store.mark_pending!(at: Time.utc(2026, 7, 14, 9, 0, 0))
      store.rollback!

      store.confirm_immediately!(at: Time.utc(2026, 7, 16, 9, 0, 0))

      expect(store.restorable?).to be false
    end
  end

  describe "#confirmed_at / #pending_at" do
    it "returns nil when the store is empty" do
      expect(store.confirmed_at).to be_nil
      expect(store.pending_at).to be_nil
    end

    it "returns nil when the stored timestamp is corrupt" do
      FileUtils.mkdir_p(work_dir)
      File.write(store.path, JSON.generate("confirmed_at" => "not-a-timestamp", "pending_at" => nil, "rollback_at" => nil))

      expect(store.confirmed_at).to be_nil
    end
  end

  describe "#load (migration)" do
    it "returns all-nil defaults when neither last_fetch.json nor the legacy file exists" do
      expect(store.load).to eq("confirmed_at" => nil, "pending_at" => nil, "rollback_at" => nil, "last_op" => nil)
    end

    # last_op 導入前に書かれた新形式ファイルには last_op キーが無い。読み込み時に補う。
    it "fills in last_op for a pre-last_op new-format file" do
      confirmed = Time.utc(2026, 7, 14, 9, 0, 0)
      File.write(store.path, JSON.generate("confirmed_at" => confirmed.iso8601, "pending_at" => nil, "rollback_at" => nil))

      data = store.load

      expect(data["confirmed_at"]).to eq(confirmed.iso8601)
      expect(data).to have_key("last_op")
      expect(data["last_op"]).to be_nil
    end

    it "migrates a legacy mode-keyed last_fetch.json (publish present) into confirmed_at" do
      digest_at = Time.utc(2026, 7, 10, 8, 0, 0)
      publish_at = Time.utc(2026, 7, 12, 8, 0, 0)
      File.write(store.path, JSON.generate("digest" => digest_at.iso8601, "publish" => publish_at.iso8601))

      data = store.load

      expect(data["confirmed_at"]).to eq(publish_at.iso8601)
      expect(data["pending_at"]).to be_nil
      expect(data["rollback_at"]).to be_nil
    end

    it "migrates a legacy mode-keyed last_fetch.json (digest only) into confirmed_at" do
      digest_at = Time.utc(2026, 7, 10, 8, 0, 0)
      File.write(store.path, JSON.generate("digest" => digest_at.iso8601))

      data = store.load

      expect(data["confirmed_at"]).to eq(digest_at.iso8601)
    end

    it "migrates the legacy last_fetch.txt into confirmed_at" do
      at = Time.utc(2026, 7, 10, 8, 0, 0)
      File.write(store.legacy_path, at.iso8601)

      data = store.load

      expect(data["confirmed_at"]).to eq(at.iso8601)
      expect(File.exist?(store.legacy_path)).to be false
      expect(File.exist?(store.path)).to be true
    end

    it "leaves a corrupt legacy last_fetch.txt untouched and returns defaults" do
      File.write(store.legacy_path, "not-a-timestamp")

      expect(store.load).to eq("confirmed_at" => nil, "pending_at" => nil, "rollback_at" => nil, "last_op" => nil)
      expect(File.exist?(store.legacy_path)).to be true
    end

    it "leaves a corrupt last_fetch.json untouched and returns defaults" do
      FileUtils.mkdir_p(work_dir)
      File.write(store.path, "not-json")

      expect(store.load).to eq("confirmed_at" => nil, "pending_at" => nil, "rollback_at" => nil, "last_op" => nil)
      expect(File.read(store.path)).to eq("not-json")
    end
  end
end
