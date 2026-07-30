# frozen_string_literal: true

require "spec_helper"
require "internal/r2_storage"

RSpec.describe Internal::R2Storage do
  let(:client) { Aws::S3::Client.new(stub_responses: true, region: "auto") }
  let(:storage) { described_class.new(bucket: "test-bucket", client: client) }

  describe "#audio_key / #archive_key" do
    it "places episode files under the audio prefix" do
      expect(storage.audio_key("ep.mp3")).to eq("audio/ep.mp3")
    end

    it "honours a custom audio prefix" do
      custom = described_class.new(bucket: "b", client: client, audio_prefix: "media")

      expect(custom.audio_key("ep.mp3")).to eq("media/ep.mp3")
    end

    # 退避先を audio プレフィックス配下にすると Worker が R2 から配信し続けてしまい、
    # retention を超えたエピソードが公開されたままになる。
    it "places archived files outside the audio prefix" do
      expect(storage.archive_key("ep.mp3")).to eq("archived/ep.mp3")
      expect(storage.archive_key("ep.mp3")).not_to start_with("audio/")
    end
  end

  describe "#exist?" do
    it "returns true when head_object succeeds" do
      client.stub_responses(:head_object, {})

      expect(storage.exist?("archives.csv")).to be true
    end

    it "returns false on NotFound" do
      client.stub_responses(:head_object, "NotFound")

      expect(storage.exist?("archives.csv")).to be false
    end

    # 「確認できなかった」を「存在しない」と誤ると、既存台帳を初回扱いで
    # 上書きして過去エピソードの履歴を失う。
    it "raises on a transient failure instead of reporting absence" do
      client.stub_responses(:head_object, "InternalError")

      expect { storage.exist?("archives.csv") }.to raise_error(Aws::S3::Errors::ServiceError)
    end

    it "raises on an auth failure instead of reporting absence" do
      client.stub_responses(:head_object, "AccessDenied")

      expect { storage.exist?("archives.csv") }.to raise_error(Aws::S3::Errors::ServiceError)
    end
  end

  describe "#put" do
    it "sends content_type and cache_control" do
      captured = nil
      client.stub_responses(:put_object, ->(ctx) { captured = ctx.params; {} })

      storage.put("feed.xml", "<feed/>", content_type: "application/atom+xml", cache_control: "public, max-age=300")

      expect(captured[:content_type]).to eq("application/atom+xml")
      expect(captured[:cache_control]).to eq("public, max-age=300")
      expect(captured[:body]).to eq("<feed/>")
    end

    it "omits cache_control when not given" do
      captured = nil
      client.stub_responses(:put_object, ->(ctx) { captured = ctx.params; {} })

      storage.put("a.txt", "x", content_type: "text/plain")

      expect(captured).not_to have_key(:cache_control)
    end
  end

  describe "#get" do
    it "returns the object body" do
      client.stub_responses(:get_object, { body: "a,b,c\n" })

      expect(storage.get("archives.csv")).to eq("a,b,c\n")
    end

    it "raises Missing when the key does not exist" do
      client.stub_responses(:get_object, "NoSuchKey")

      expect { storage.get("archives.csv") }.to raise_error(described_class::Missing, /archives\.csv/)
    end
  end

  describe "#move" do
    it "copies before deleting so a mid-failure leaves the source intact" do
      calls = []
      client.stub_responses(:head_object, {})
      client.stub_responses(:copy_object, ->(_ctx) { calls << :copy; { copy_object_result: {} } })
      client.stub_responses(:delete_object, ->(_ctx) { calls << :delete; {} })

      storage.move("audio/ep.mp3", "archived/ep.mp3")

      expect(calls).to eq(%i[copy delete])
    end

    it "does not delete the source when the copy fails" do
      deleted = false
      client.stub_responses(:head_object, {})
      client.stub_responses(:copy_object, "InternalError")
      client.stub_responses(:delete_object, ->(_ctx) { deleted = true; {} })

      expect { storage.move("audio/ep.mp3", "archived/ep.mp3") }.to raise_error(Aws::S3::Errors::ServiceError)
      expect(deleted).to be false
    end

    it "passes copy_source including the bucket name" do
      captured = nil
      client.stub_responses(:head_object, {})
      client.stub_responses(:copy_object, ->(ctx) { captured = ctx.params; { copy_object_result: {} } })
      client.stub_responses(:delete_object, {})

      storage.move("audio/ep.mp3", "archived/ep.mp3")

      expect(captured[:copy_source]).to eq("test-bucket/audio/ep.mp3")
    end

    # 退避済み（元が無く退避先にある）なら再実行しても何もしない。
    it "is idempotent when the object was already moved" do
      calls = []
      responses = ["NotFound", {}] # from_key は無い / to_key はある
      client.stub_responses(:head_object, ->(_ctx) { responses.shift })
      client.stub_responses(:copy_object, ->(_ctx) { calls << :copy; { copy_object_result: {} } })

      expect(storage.move("audio/ep.mp3", "archived/ep.mp3")).to eq(:already_moved)
      expect(calls).to be_empty
    end
  end

  describe "#delete_prefix" do
    it "deletes every listed key and reports the count" do
      client.stub_responses(:list_objects_v2, {
        contents: [{ key: "archived/a.mp3" }, { key: "archived/b.mp3" }], is_truncated: false,
      })
      captured = nil
      client.stub_responses(:delete_objects, ->(ctx) { captured = ctx.params; {} })

      expect(storage.delete_prefix("archived/")).to eq(2)
      expect(captured[:delete][:objects]).to eq([{ key: "archived/a.mp3" }, { key: "archived/b.mp3" }])
    end

    it "returns 0 and issues no delete when the prefix is empty" do
      client.stub_responses(:list_objects_v2, { contents: [], is_truncated: false })
      called = false
      client.stub_responses(:delete_objects, ->(_ctx) { called = true; {} })

      expect(storage.delete_prefix("archived/")).to eq(0)
      expect(called).to be false
    end

    it "follows pagination across truncated listings" do
      pages = [
        { contents: [{ key: "archived/a" }], is_truncated: true, next_continuation_token: "t1" },
        { contents: [{ key: "archived/b" }], is_truncated: false },
      ]
      client.stub_responses(:list_objects_v2, ->(_ctx) { pages.shift })
      client.stub_responses(:delete_objects, {})

      expect(storage.delete_prefix("archived/")).to eq(2)
    end
  end
end
