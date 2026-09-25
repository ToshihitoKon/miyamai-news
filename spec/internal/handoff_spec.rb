# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "internal/handoff"
require_relative "../support/in_memory_storage"

RSpec.describe Internal::Handoff do
  let(:storage) { InMemoryStorage.new }
  let(:episode_key) { "20260714_afternoon" }
  let(:contents) { { tts_script: "宮舞モカです。[interval:mid]", script: "宮舞モカです。", used_news: "## 生成AI\n" } }

  subject(:handoff) { described_class.new(storage: storage) }

  describe "#upload! / #exist?" do
    it "writes every file under handoff/<episode_key>/ and then reports the handoff as present" do
      handoff.upload!(episode_key, contents)

      expect(storage.get("handoff/20260714_afternoon/tts_script.txt")).to eq(contents[:tts_script])
      expect(storage.list("handoff/20260714_afternoon/").size).to eq(3)
      expect(handoff.exist?(episode_key)).to be true
    end

    it "is false while some files are missing (an interrupted upload)" do
      storage.put("handoff/20260714_afternoon/tts_script.txt", "partial", content_type: "text/plain")
      storage.put("handoff/20260714_afternoon/script.txt", "partial", content_type: "text/plain")

      expect(handoff.exist?(episode_key)).to be false
    end
  end

  describe "#pending_episode_keys" do
    it "lists only episodes whose files are all present, from a single listing" do
      handoff.upload!(episode_key, contents)
      handoff.upload!("20260714_morning", contents)
      storage.put("handoff/20260714_evening/tts_script.txt", "partial", content_type: "text/plain")
      storage.put("handoff/stray.txt", "stray", content_type: "text/plain")
      allow(storage).to receive(:exist?).and_call_original

      expect(handoff.pending_episode_keys).to contain_exactly(episode_key, "20260714_morning")
      expect(storage).not_to have_received(:exist?)
    end
  end

  describe "#download!" do
    it "writes each file to the given local path" do
      handoff.upload!(episode_key, contents)

      Dir.mktmpdir do |dir|
        paths = contents.keys.to_h { |name| [name, File.join(dir, "#{name}.txt")] }
        handoff.download!(episode_key, paths)

        contents.each { |name, body| expect(File.read(paths[name])).to eq(body) }
      end
    end

    it "raises NotFound when the handoff is incomplete" do
      storage.put("handoff/20260714_afternoon/tts_script.txt", "partial", content_type: "text/plain")

      expect { handoff.download!(episode_key, {}) }.to raise_error(described_class::NotFound)
    end
  end

  describe "#mark_done!" do
    it "moves the whole handoff to handoff_done/, tts_script first" do
      handoff.upload!(episode_key, contents)
      moved = []
      allow(storage).to receive(:move).and_wrap_original do |original, from, to|
        moved << from
        original.call(from, to)
      end

      expect(handoff.mark_done!(episode_key)).to eq(3)

      expect(moved.first).to eq("handoff/20260714_afternoon/tts_script.txt")
      expect(storage.list("handoff/")).to be_empty
      expect(storage.list("handoff_done/20260714_afternoon/").size).to eq(3)
      expect(handoff.exist?(episode_key)).to be false
    end

    it "moves only what is left after an interrupted mark_done!" do
      handoff.upload!(episode_key, contents)
      storage.move("handoff/20260714_afternoon/tts_script.txt", "handoff_done/20260714_afternoon/tts_script.txt")

      expect(handoff.exist?(episode_key)).to be false
      expect(handoff.mark_done!(episode_key)).to eq(2)
      expect(storage.list("handoff/")).to be_empty
    end

    it "does nothing when there is no handoff for the episode" do
      expect(handoff.mark_done!(episode_key)).to eq(0)
    end
  end
end
