# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "internal/remote_state"
require_relative "../support/in_memory_storage"

RSpec.describe Internal::RemoteState do
  let(:work_dir) { Dir.mktmpdir }
  let(:storage) { InMemoryStorage.new(remote_objects) }
  let(:remote_objects) do
    {
      "state_revision" => "rev-1",
      "state/last_fetch.json" => '{"confirmed_at":"2026-07-14T12:00:00+09:00"}',
      "state/feed_cache/abc.json" => '{"entries":{}}',
      "state/used_news_history/20260714_morning.txt" => "## 生成AI\n### 過去の話題\n"
    }
  end

  subject(:state) { described_class.new(storage: storage, work_dir: work_dir) }

  after { FileUtils.remove_entry(work_dir) }

  # work/state/ 以下（内部状態）のパス。
  def local(relative) = File.join(work_dir, "state", relative)

  def write_local(relative, body) = write_file(local(relative), body)

  # work/ 直下（回ごとの中間ファイル）。
  def write_work(relative, body) = write_file(File.join(work_dir, relative), body)

  def write_file(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  describe "#checkout!" do
    it "pulls every state/ object into work/state/ and records the revision it came from" do
      expect(state.checkout!(owner: "20260714_afternoon")).to eq(:pulled)

      expect(File.read(local("last_fetch.json"))).to include("confirmed_at")
      expect(File.exist?(local("feed_cache/abc.json"))).to be true
      expect(File.read(local("used_news_history/20260714_morning.txt"))).to include("過去の話題")
      expect(state.checked_out_by).to eq("20260714_afternoon")
    end

    it "removes local tracked files that do not exist in R2, but leaves per-episode intermediate files alone" do
      write_local("used_news_history/20260101_morning.txt", "stale")
      write_work("news_20260714_afternoon.txt", "intermediate")

      state.checkout!(owner: "20260714_afternoon")

      expect(File.exist?(local("used_news_history/20260101_morning.txt"))).to be false
      expect(File.exist?(File.join(work_dir, "news_20260714_afternoon.txt"))).to be true
    end

    it "keeps the local working copy of an unfinished run when R2 is still at the revision it came from" do
      state.checkout!(owner: "20260714_afternoon")
      write_local("last_fetch.json", '{"pending_at":"2026-07-14T15:00:00+09:00"}')

      expect(described_class.new(storage: storage, work_dir: work_dir).checkout!(owner: "20260714_evening")).to eq(:resumed)
      expect(File.read(local("last_fetch.json"))).to include("pending_at")
    end

    it "raises Conflict without touching local files when R2 moved on after an unfinished run checked out" do
      state.checkout!(owner: "20260714_afternoon")
      write_local("last_fetch.json", "local unfinished")
      storage.put("state_revision", "rev-2", content_type: "text/plain")

      expect { described_class.new(storage: storage, work_dir: work_dir).checkout!(owner: "20260714_evening") }
        .to raise_error(described_class::Conflict, /--clean/)
      expect(File.read(local("last_fetch.json"))).to eq("local unfinished")
    end

    it "raises Missing when state/ exists but the revision object is gone (conflicts could no longer be detected)" do
      storage.delete("state_revision")

      expect { state.checkout!(owner: "20260714_afternoon") }.to raise_error(described_class::Missing, /state_revision/)
    end

    it "raises Missing without touching local files when R2 has no state" do
      empty_state = described_class.new(storage: InMemoryStorage.new, work_dir: work_dir)
      write_local("last_fetch.json", "local")

      expect { empty_state.checkout!(owner: "20260714_afternoon") }.to raise_error(described_class::Missing)
      expect(File.read(local("last_fetch.json"))).to eq("local")
    end
  end

  describe "#release!" do
    it "drops the working copy marker so the next checkout! pulls from R2 again" do
      state.checkout!(owner: "fetch-window-command")
      write_local("last_fetch.json", "local only")

      state.release!

      expect(state.checked_out_by).to be_nil
      expect(state.checkout!(owner: "20260714_afternoon")).to eq(:pulled)
      expect(File.read(local("last_fetch.json"))).to include("confirmed_at")
    end
  end

  describe "#ensure_current!" do
    it "raises NotCheckedOut before checkout!" do
      expect { state.ensure_current! }.to raise_error(described_class::NotCheckedOut)
    end

    it "raises Conflict when the revision object disappeared after checkout!" do
      state.checkout!(owner: "20260714_afternoon")
      storage.delete("state_revision")

      expect { state.ensure_current! }.to raise_error(described_class::Conflict)
    end

    it "raises Conflict when another run pushed after checkout!" do
      state.checkout!(owner: "20260714_afternoon")
      storage.put("state_revision", "rev-2", content_type: "text/plain")

      expect { state.ensure_current! }.to raise_error(described_class::Conflict)
    end
  end

  describe "#push!" do
    it "refuses to push when the state was not checked out" do
      expect { state.push! }.to raise_error(described_class::NotCheckedOut)
      expect(storage.objects).to eq(remote_objects)
    end

    it "uploads local tracked files, deletes R2 keys that no longer exist locally, and advances the revision" do
      state.checkout!(owner: "20260714_afternoon")
      File.delete(local("used_news_history/20260714_morning.txt"))
      write_local("used_news_history/20260714_afternoon.txt", "## 生成AI\n### 新しい話題\n")
      write_local("last_fetch.json", '{"confirmed_at":"2026-07-14T15:00:00+09:00"}')
      write_work("news_20260714_afternoon.txt", "intermediate")

      state.push!

      expect(storage.list("state/")).to eq(%w[
        state/feed_cache/abc.json state/last_fetch.json state/used_news_history/20260714_afternoon.txt
      ])
      expect(storage.get("state/last_fetch.json")).to include("15:00:00")
      expect(storage.get("state_revision")).not_to eq("rev-1")
      expect(File.exist?(File.join(work_dir, described_class::BASE_REVISION_FILE))).to be false
    end

    it "advances the revision before syncing, so an interrupted sync resumes here and conflicts elsewhere" do
      state.checkout!(owner: "20260714_afternoon")
      other = described_class.new(storage: storage, work_dir: Dir.mktmpdir)
      other.checkout!(owner: "20260714_afternoon")
      allow(storage).to receive(:sync_up).and_raise(StandardError, "delete failed")

      expect { state.push! }.to raise_error(StandardError, "delete failed")

      expect(storage.get("state_revision")).not_to eq("rev-1")
      expect(described_class.new(storage: storage, work_dir: work_dir).checkout!(owner: "20260714_afternoon")).to eq(:resumed)
      expect { other.ensure_current! }.to raise_error(described_class::Conflict)
    end

    it "does not upload leftovers of interrupted tmp-then-rename writes" do
      state.checkout!(owner: "20260714_afternoon")
      write_local("last_fetch.json.tmp", "half written")
      write_local("feed_cache/abc.json.tmp", "half written")

      state.push!

      expect(storage.list("state/").grep(/\.tmp\z/)).to be_empty
      expect(File.exist?(local("last_fetch.json.tmp"))).to be false
    end

    it "refuses to overwrite R2 when another run pushed after checkout!" do
      state.checkout!(owner: "20260714_afternoon")
      storage.put("state_revision", "rev-2", content_type: "text/plain")
      write_local("last_fetch.json", "mine")

      expect { state.push! }.to raise_error(described_class::Conflict)
      expect(storage.get("state/last_fetch.json")).to include("confirmed_at")
    end
  end

  describe "#seed!" do
    it "uploads local tracked files and a revision when R2 has no state" do
      empty_storage = InMemoryStorage.new
      write_local("last_fetch.json", "{}")
      write_local("feed_cache.json", "{}")

      described_class.new(storage: empty_storage, work_dir: work_dir).seed!

      expect(empty_storage.list("state/")).to eq(%w[state/feed_cache.json state/last_fetch.json])
      expect(empty_storage.exist?("state_revision")).to be true
    end

    it "refuses to overwrite existing R2 state" do
      write_local("last_fetch.json", "{}")

      expect { state.seed! }.to raise_error(ArgumentError, /already exists/)
      expect(storage.objects).to eq(remote_objects)
    end
  end
end
