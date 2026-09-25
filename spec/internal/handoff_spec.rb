# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "internal/handoff"
require_relative "../support/in_memory_storage"

RSpec.describe Internal::Handoff do
  let(:storage) { InMemoryStorage.new }
  let(:episode_key) { "20260714_afternoon" }
  let(:contents) { { tts_script: "宮舞モカです。[interval:mid]", script: "宮舞モカです。", used_news: "## 生成AI\n" } }

  subject(:handoff) { described_class.new(storage: storage) }

  def upload_and_commit
    handoff.upload_files!(episode_key, contents)
    handoff.commit!(episode_key)
  end

  describe "#upload_files! / #commit!" do
    it "is not visible until commit! writes the manifest" do
      handoff.upload_files!(episode_key, contents)

      expect(storage.get("handoff/20260714_afternoon/tts_script.txt")).to eq(contents[:tts_script])
      expect(handoff.exist?(episode_key)).to be false

      handoff.commit!(episode_key)

      expect(handoff.exist?(episode_key)).to be true
      expect(JSON.parse(storage.get("handoff/20260714_afternoon/manifest.json"))["episode_key"]).to eq(episode_key)
    end
  end

  describe "#download!" do
    it "writes each file to the given local path" do
      upload_and_commit

      Dir.mktmpdir do |dir|
        paths = contents.keys.to_h { |name| [name, File.join(dir, "#{name}.txt")] }
        handoff.download!(episode_key, paths)

        contents.each { |name, body| expect(File.read(paths[name])).to eq(body) }
      end
    end

    it "raises NotFound when the handoff is not committed" do
      handoff.upload_files!(episode_key, contents)

      expect { handoff.download!(episode_key, {}) }.to raise_error(described_class::NotFound)
    end
  end

  describe "#mark_done!" do
    it "moves the whole handoff to handoff_done/, manifest first" do
      upload_and_commit
      moved = []
      allow(storage).to receive(:move).and_wrap_original do |original, from, to|
        moved << from
        original.call(from, to)
      end

      expect(handoff.mark_done!(episode_key)).to eq(4)

      expect(moved.first).to eq("handoff/20260714_afternoon/manifest.json")
      expect(storage.list("handoff/")).to be_empty
      expect(storage.list("handoff_done/20260714_afternoon/").size).to eq(4)
      expect(handoff.exist?(episode_key)).to be false
    end

    it "moves only what is left after an interrupted mark_done!" do
      upload_and_commit
      storage.move("handoff/20260714_afternoon/manifest.json", "handoff_done/20260714_afternoon/manifest.json")

      expect(handoff.mark_done!(episode_key)).to eq(3)
      expect(storage.list("handoff/")).to be_empty
    end

    it "does nothing when there is no handoff for the episode" do
      expect(handoff.mark_done!(episode_key)).to eq(0)
    end
  end
end
