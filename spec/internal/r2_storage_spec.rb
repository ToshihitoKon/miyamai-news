# frozen_string_literal: true

require "spec_helper"
require "internal/r2_storage"

RSpec.describe Internal::R2Storage do
  let(:client) { Aws::S3::Client.new(stub_responses: true, region: "auto") }
  let(:storage) { described_class.new(bucket: "test-bucket", client: client) }

  describe "#episode_key / #archive_key" do
    it "places episode files under the episode prefix" do
      expect(storage.episode_key("ep.mp3")).to eq("episodes/ep.mp3")
    end

    it "honours a custom episode prefix" do
      custom = described_class.new(bucket: "b", client: client, episode_prefix: "media")

      expect(custom.episode_key("ep.mp3")).to eq("media/ep.mp3")
    end

    # 退避先を episodes プレフィックス配下にすると Worker が R2 から配信し続けてしまい、
    # retention を超えたエピソードが公開されたままになる。
    it "places archived files outside the episode prefix" do
      expect(storage.archive_key("ep.mp3")).to eq("archived/ep.mp3")
      expect(storage.archive_key("ep.mp3")).not_to start_with("episodes/")
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
      client.stub_responses(:put_object, ->(ctx) {
        captured = ctx.params
        {}
      })

      storage.put("feed.xml", "<feed/>", content_type: "application/atom+xml", cache_control: "public, max-age=300")

      expect(captured[:content_type]).to eq("application/atom+xml")
      expect(captured[:cache_control]).to eq("public, max-age=300")
      expect(captured[:body]).to eq("<feed/>")
    end

    it "omits cache_control when not given" do
      captured = nil
      client.stub_responses(:put_object, ->(ctx) {
        captured = ctx.params
        {}
      })

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

      expect { storage.get("archives.csv") }
        .to raise_error(Internal::ObjectStorage::ObjectNotFound, /archives\.csv/)
    end
  end

  describe "#move" do
    it "copies before deleting so a mid-failure leaves the source intact" do
      calls = []
      client.stub_responses(:head_object, {})
      client.stub_responses(:copy_object, ->(_ctx) {
        calls << :copy
        { copy_object_result: {} }
      })
      client.stub_responses(:delete_object, ->(_ctx) {
        calls << :delete
        {}
      })

      storage.move("episodes/ep.mp3", "archived/ep.mp3")

      expect(calls).to eq([:copy, :delete])
    end

    it "does not delete the source when the copy fails" do
      deleted = false
      client.stub_responses(:head_object, {})
      client.stub_responses(:copy_object, "InternalError")
      client.stub_responses(:delete_object, ->(_ctx) {
        deleted = true
        {}
      })

      expect { storage.move("episodes/ep.mp3", "archived/ep.mp3") }.to raise_error(Aws::S3::Errors::ServiceError)
      expect(deleted).to be false
    end

    it "passes copy_source including the bucket name" do
      captured = nil
      client.stub_responses(:head_object, {})
      client.stub_responses(:copy_object, ->(ctx) {
        captured = ctx.params
        { copy_object_result: {} }
      })
      client.stub_responses(:delete_object, {})

      storage.move("episodes/ep.mp3", "archived/ep.mp3")

      expect(captured[:copy_source]).to eq("test-bucket/episodes/ep.mp3")
    end

    # 退避済み（元が無く退避先にある）なら再実行しても何もしない。
    it "is idempotent when the object was already moved" do
      calls = []
      responses = ["NotFound", {}] # from_key は無い / to_key はある
      client.stub_responses(:head_object, ->(_ctx) { responses.shift })
      client.stub_responses(:copy_object, ->(_ctx) {
        calls << :copy
        { copy_object_result: {} }
      })

      expect(storage.move("episodes/ep.mp3", "archived/ep.mp3")).to eq(:already_moved)
      expect(calls).to be_empty
    end
  end

  # クライアントは遅延生成なので、@client を直接参照するメソッドがあると
  # 注入なしの実運用経路だけ nil で落ちる（spec は常に注入するので気づけない）。
  describe "lazy client wiring" do
    it "builds the client on first use for every request method" do
      ENV["R2_ACCESS_KEY_ID"] = "test-key"
      ENV["R2_SECRET_ACCESS_KEY"] = "test-secret"
      lazy = described_class.new(bucket: "b", account_id: "acct")

      # 認証情報だけ用意して、各メソッドが nil 参照で落ちないことを見る。
      # 実際の通信は行わないので接続エラーで止まる分には問題ない。
      [:list, :exist?].each do |method|
        lazy.public_send(method, "prefix/")
      rescue Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError
        nil # 通信段階まで到達していればクライアントは組み立てられている
      end
    ensure
      ENV.delete("R2_ACCESS_KEY_ID")
      ENV.delete("R2_SECRET_ACCESS_KEY")
    end
  end

  describe "#delete_prefix" do
    it "deletes every listed key and reports the count" do
      client.stub_responses(:list_objects_v2, {
        contents: [{ key: "archived/a.mp3" }, { key: "archived/b.mp3" }], is_truncated: false,
      })
      captured = nil
      client.stub_responses(:delete_objects, ->(ctx) {
        captured = ctx.params
        {}
      })

      expect(storage.delete_prefix("archived/")).to eq(2)
      expect(captured[:delete][:objects]).to eq([{ key: "archived/a.mp3" }, { key: "archived/b.mp3" }])
    end

    it "returns 0 and issues no delete when the prefix is empty" do
      client.stub_responses(:list_objects_v2, { contents: [], is_truncated: false })
      called = false
      client.stub_responses(:delete_objects, ->(_ctx) {
        called = true
        {}
      })

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
