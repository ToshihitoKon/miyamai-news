# frozen_string_literal: true

module Internal
  # facts ファイル（work/news_facts_<date_tag>_<slot>.txt、templates/extractor.prompt.erb
  # が生成する Markdown）を、カテゴリ・記事単位の全文チャンクへ分割できる構造に変換する。
  # UsedNewsMarkdown と同じ「行単位パース + Result struct」の設計パターンを踏襲するが、
  # 目的が異なる: UsedNewsMarkdown は表示用 HTML への変換、FactsFullText は Slack/Discord へ
  # 全文投稿するための構造境界の判定のみを行う（詳細は CLAUDE.md「Notifier」参照）。
  #
  # 記事の中身（URL・発行元・日付・要点・関連技術）はフィールドに分解せず、見出し行から
  # 次の見出し直前までの生の行を raw_lines にそのまま積む。分解して後で再構成すると
  # 再構成漏れによる情報欠落が起こりうるため、全文保持を実装レベルで保証する。
  module FactsFullText
    module_function

    # ok=false のとき categories は空配列。呼び出し側（Notifier）は生テキスト全体を
    # チャンク分割して投稿するフォールバック経路を持つ。
    Result = Struct.new(:ok, :categories, keyword_init: true)
    Category = Struct.new(:label, :articles, keyword_init: true)
    # kind: "メイン" | "補欠"。raw_lines は見出し行自身を含む chomp 済みの行配列。
    Article = Struct.new(:kind, :title, :raw_lines, keyword_init: true)

    RE_CATEGORY = /\A##\s+(.+?)\s*\z/
    RE_ARTICLE = /\A###\s+\[(メイン|補欠)\]\s*(.+?)\s*\z/

    def parse(text)
      lines = text.to_s.lines.map(&:chomp)
      return failure unless lines.any? { |line| line.match?(RE_CATEGORY) }
      return failure unless lines.any? { |line| line.match?(RE_ARTICLE) }

      categories = []
      current_category = nil
      current_article = nil

      flush_article = -> do
        current_category.articles << current_article if current_article
        current_article = nil
      end

      lines.each do |line|
        if (m = line.match(RE_CATEGORY))
          flush_article.call
          current_category = Category.new(label: m[1], articles: [])
          categories << current_category
        elsif (m = line.match(RE_ARTICLE))
          # カテゴリ見出しより前に記事見出しが来る（孤立記事）は破損とみなす。
          return failure unless current_category

          flush_article.call
          current_article = Article.new(kind: m[1], title: m[2], raw_lines: [line])
        elsif current_article
          current_article.raw_lines << line
        end
        # カテゴリ確定前・記事確定前の行（"---" 区切りや空行）は無視する。
      end
      flush_article.call

      Result.new(ok: true, categories: categories)
    rescue StandardError
      failure
    end

    def failure = Result.new(ok: false, categories: [])
  end
end
