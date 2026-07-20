# frozen_string_literal: true

require "spec_helper"
require "internal/used_news_markdown"

RSpec.describe UsedNewsMarkdown do
  # 新フォーマット（## カテゴリ / ### [タイトル](URL) / 要約 / (date / source)）の
  # 典型サンプル。文法の各要素が 1 通り出そろうよう最小限にする。
  NEW_FORMAT = <<~USED
    ## 生成AI
    ### [Gemini 3.5 Pro が延期か](https://example.com/gemini)
       次世代 LLM の開発が難航しているという観測。
       (2026-07-17 / 財経新聞)

    ## セキュリティ
    ### [wp2shell 公開](https://example.com/wp2shell)
       WordPress Core に未認証 RCE の脆弱性チェーン。
       (2026-07-19 / piyolog (著者: piyokango))
  USED

  # 移行前の旧フォーマット（■ 見出し / ・タイトル / 独立 URL 行）。
  OLD_FORMAT = <<~USED
    ■ 生成AI
    ・Gemini 3.5 Pro が延期か
       次世代 LLM の開発が難航しているという観測。
       https://example.com/gemini
       (2026-07-17 / 財経新聞)
  USED

  describe ".render" do
    it "wraps categories, titles, summaries, and meta in the expected divs" do
      result = described_class.render(NEW_FORMAT)

      expect(result.ok).to be true
      expect(result.html).to include('<div class="news-cat">生成AI</div>')
      expect(result.html).to include(
        '<div class="news-title"><a href="https://example.com/gemini" target="_blank" rel="noopener">Gemini 3.5 Pro が延期か</a></div>'
      )
      expect(result.html).to include('<p class="news-sum">次世代 LLM の開発が難航しているという観測。</p>')
      expect(result.html).to include('<div class="news-meta">(2026-07-17 / 財経新聞)</div>')
      expect(result.html).to include('<div class="news-cat">セキュリティ</div>')
    end

    it "links the title to the article URL" do
      result = described_class.render(NEW_FORMAT)

      expect(result.html).to include('href="https://example.com/wp2shell"')
      expect(result.html).to include(">wp2shell 公開</a>")
    end

    it "keeps a ] inside the title (greedy match on the closing bracket)" do
      text = <<~USED
        ## その他
        ### [GitHub - ayghri/i-have-adhd: Claude Code skill [beta]](https://example.com/repo)
           結論ファーストで出力させる設定スキル。
           (2026-07-19 / GitHub)
      USED

      result = described_class.render(text)

      expect(result.ok).to be true
      expect(result.html).to include(">GitHub - ayghri/i-have-adhd: Claude Code skill [beta]</a>")
      expect(result.html).to include('href="https://example.com/repo"')
    end

    it "does not linkify a non-http scheme (XSS guard)" do
      text = <<~USED
        ## 生成AI
        ### [クリック](javascript:alert(1))
           怪しいリンク。
      USED

      result = described_class.render(text)

      expect(result.ok).to be true
      expect(result.html).not_to include("<a ")
      expect(result.html).to include('<div class="news-title">クリック</div>')
    end

    it "HTML-escapes titles, summaries, and meta" do
      text = <<~USED
        ## 生成AI
        ### [<script>&"](https://example.com/x)
           要約に <b> と & を含む。
      USED

      result = described_class.render(text)

      expect(result.html).to include("&lt;script&gt;&amp;&quot;")
      expect(result.html).to include("&lt;b&gt; と &amp;")
      expect(result.html).not_to include("<script>")
    end

    it "returns ok:false for the old format (no ## heading)" do
      expect(described_class.render(OLD_FORMAT).ok).to be false
    end

    it "returns ok:false when there is a ## heading but no ### title line" do
      text = <<~USED
        ## 生成AI
        本文だけで記事タイトル行が無い。
      USED

      expect(described_class.render(text).ok).to be false
    end

    it "returns ok:false when a title appears before any category (orphan)" do
      text = <<~USED
        ### [見出し前のタイトル](https://example.com/x)
           要約。
        ## 生成AI
      USED

      expect(described_class.render(text).ok).to be false
    end

    it "returns ok:false for empty text" do
      expect(described_class.render("").ok).to be false
    end
  end
end
