# frozen_string_literal: true

require "spec_helper"
require "internal/facts_full_text"

RSpec.describe Internal::FactsFullText do
  describe ".parse" do
    context "正常系" do
      it "カテゴリ・記事の見出しから構造を組み立て、本文を raw_lines にそのまま保持する" do
        text = <<~TEXT
          ## 生成AI

          ### [メイン] Title A
          - **URL**: https://example.com/a
          - **要点・要約**:
            - 仕組み・技術的な中身: 説明A

          ### [補欠] Title B
          - **URL**: https://example.com/b
          - **要点・要約**:
            - 要点B

          ## セキュリティ

          ### [メイン] Title C
          - **URL**: https://example.com/c
        TEXT

        result = described_class.parse(text)

        expect(result.ok).to be true
        expect(result.categories.map(&:label)).to eq(%w[生成AI セキュリティ])
        expect(result.categories[0].articles.map(&:kind)).to eq(%w[メイン 補欠])
        expect(result.categories[0].articles.map(&:title)).to eq(["Title A", "Title B"])
        expect(result.categories[1].articles.map(&:title)).to eq(["Title C"])
      end

      it "各記事の raw_lines を連結すると入力の該当範囲を完全に復元できる（情報欠落なしの保証）" do
        text = <<~TEXT
          ## 生成AI

          ### [メイン] Title A
          - **URL**: https://example.com/a
          - **要点・要約**:
            - 仕組み・技術的な中身: 説明A
            - インパクト・今後への影響: 説明B
          - **関連技術**: Foo, Bar
        TEXT

        result = described_class.parse(text)
        article = result.categories.first.articles.first

        expect(article.raw_lines.join("\n")).to eq(<<~EXPECTED.chomp)
          ### [メイン] Title A
          - **URL**: https://example.com/a
          - **要点・要約**:
            - 仕組み・技術的な中身: 説明A
            - インパクト・今後への影響: 説明B
          - **関連技術**: Foo, Bar
        EXPECTED
      end

      it "実際の facts ファイル相当の fixture を全件パースできる" do
        text = File.read(File.expand_path("../fixtures/news_facts_sample.txt", __dir__))

        result = described_class.parse(text)

        expect(result.ok).to be true
        expect(result.categories.map(&:label)).to eq(["生成AI", "AIエージェント・AIコーディングツール"])
        expect(result.categories[0].articles.size).to eq(2)
        expect(result.categories[1].articles.size).to eq(1)
        expect(result.categories[0].articles.map(&:kind)).to eq(%w[メイン 補欠])
      end
    end

    context "異常系" do
      it "## 見出しが1つも無ければ ok:false を返す" do
        result = described_class.parse("### [メイン] Title\n- **URL**: https://example.com\n")

        expect(result.ok).to be false
        expect(result.categories).to eq([])
      end

      it "### [メイン|補欠] 見出しが1つも無ければ ok:false を返す" do
        result = described_class.parse("## 生成AI\n本文だけ\n")

        expect(result.ok).to be false
      end

      it "カテゴリ見出しより前に記事見出しが来る（孤立記事）場合は ok:false を返す" do
        text = <<~TEXT
          ### [メイン] Title A
          - **URL**: https://example.com/a

          ## 生成AI
        TEXT

        result = described_class.parse(text)

        expect(result.ok).to be false
      end

      it "空文字列に対して ok:false を返す" do
        expect(described_class.parse("").ok).to be false
      end
    end
  end
end
