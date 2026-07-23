# frozen_string_literal: true

require "spec_helper"
require "internal/notifiers/chunker"

RSpec.describe Internal::Notifiers::Chunker do
  describe ".pack" do
    it "複数 block が limit 内に収まるなら1チャンクに結合する" do
      chunks = described_class.pack(["a" * 10, "b" * 10], limit: 30, separator: "\n\n")

      expect(chunks).to eq(["#{'a' * 10}\n\n#{'b' * 10}"])
    end

    it "block を足すと limit を超える場合は新しいチャンクに切る" do
      chunks = described_class.pack(["a" * 10, "b" * 10], limit: 15, separator: "\n\n")

      expect(chunks).to eq(["a" * 10, "b" * 10])
    end

    it "ちょうど limit に収まる block はそのまま1チャンクになる（境界値: limit）" do
      block = "a" * 20
      chunks = described_class.pack([block], limit: 20)

      expect(chunks).to eq([block])
    end

    it "limit - 1 文字の block はそのまま1チャンクになる（境界値: limit-1）" do
      block = "a" * 19
      chunks = described_class.pack([block], limit: 20)

      expect(chunks).to eq([block])
    end

    it "limit + 1 文字の block は行単位で分割される（境界値: limit+1）" do
      block = "#{'a' * 20}\nb"
      chunks = described_class.pack([block], limit: 20)

      expect(chunks).to eq(["a" * 20, "b"])
    end

    it "単一 block が limit を大きく超える場合、行単位で複数チャンクに分割される" do
      block = (1..10).map { |i| "line#{i}" }.join("\n")
      chunks = described_class.pack([block], limit: 12)

      expect(chunks.size).to be > 1
      expect(chunks.join("\n")).to eq(block)
    end

    it "1行自体が limit を超える極端なケースは文字単位でさらに分割される" do
      long_line = "x" * 50
      chunks = described_class.pack([long_line], limit: 20)

      expect(chunks).to eq(["x" * 20, "x" * 20, "x" * 10])
    end

    it "単一 block が limit を超えて行単位分割されるとき、途中の空行を取りこぼさない" do
      block = "aaaaa\n\nbbbbb"
      chunks = described_class.pack([block], limit: 5, separator: "\n")

      expect(chunks.join("\n")).to eq(block)
    end

    it "全チャンクを連結すると入力全体を復元できる（情報欠落なしの保証、limit内に収まるblockのみ）" do
      blocks = ["short", "y" * 8, "z" * 5, "line1\nline2\nline3"]
      chunks = described_class.pack(blocks, limit: 10, separator: "\n")

      expect(chunks.join("\n")).to eq(blocks.join("\n"))
    end

    it "文字数を bytesize ではなく length（コードポイント数）で数える" do
      # 日本語1文字は複数バイトだが、長さは1文字として扱われるべき。
      block = "あ" * 10
      chunks = described_class.pack([block], limit: 10)

      expect(chunks).to eq([block])
    end
  end
end
