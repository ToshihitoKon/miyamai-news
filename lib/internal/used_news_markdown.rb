# frozen_string_literal: true

require "cgi"

# used_news（この回で紹介したニュース欄）の限定 Markdown サブセット
# （## カテゴリ / ### [タイトル](URL) / メタ / 要約）を HTML に変換する。
# Publisher が publish 時にこれで HTML 化して .used.html として事前生成する
# （唯一のパーサ実装）。
module UsedNewsMarkdown
  module_function

  # render の結果。ok=false のとき html は nil で、呼び出し側は生テキスト表示へ
  # フォールバックする。
  Result = Struct.new(:ok, :html, keyword_init: true)

  RE_CATEGORY = /\A##\s+(.+?)\s*\z/
  RE_TITLE = /\A###\s+\[(.+)\]\((\S+)\)\s*\z/
  RE_META = /\A\s*\((.+)\)\s*\z/

  def render(text)
    lines = text.to_s.lines.map(&:chomp)
    return failure unless lines.any? { |line| line.match?(RE_CATEGORY) }
    return failure unless lines.any? { |line| line.match?(RE_TITLE) }

    html = +""
    in_category = false
    in_item = false
    orphan = false

    close_item = -> {
      html << "</div>\n" if in_item
      in_item = false
    }
    close_category = -> do
      close_item.call
      html << "</div>\n" if in_category
      in_category = false
    end

    lines.each do |line|
      if (m = line.match(RE_CATEGORY))
        close_category.call
        html << %(<h3 class="news-cat">#{h(m[1])}</h3>\n<div class="news-cat-body">\n)
        in_category = true
      elsif (m = line.match(RE_TITLE))
        orphan = true unless in_category
        close_item.call
        html << %(<div class="news-item"><p class="news-title"><strong>#{anchor(m[1], m[2])}</strong></p>\n)
        in_item = true
      elsif (m = line.match(RE_META))
        html << %(<p class="news-meta">#{h("(#{m[1]})")}</p>\n) if in_item
      elsif line.strip.empty?
        # 空行は項目区切り。何もしない。
      elsif in_item
        html << %(<p class="news-sum">#{h(line.strip)}</p>\n)
      end
    end
    close_category.call

    return failure if orphan

    Result.new(ok: true, html: html)
  rescue StandardError
    failure
  end

  def failure = Result.new(ok: false, html: nil)

  # スキームが http/https のときだけリンク化する。javascript: 等はプレーン表示にする。
  def anchor(title, url)
    return h(title) unless url.match?(%r{\Ahttps?://}i)

    %(<a href="#{h(url)}" target="_blank" rel="noopener">#{h(title)}</a>)
  end

  def h(str) = CGI.escapeHTML(str.to_s)
end
