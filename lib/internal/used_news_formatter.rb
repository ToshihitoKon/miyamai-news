# frozen_string_literal: true

require "set"
require "tmpdir"
require_relative "config"
require_relative "ai_cli"
require_relative "template_renderer"
require_relative "used_news_markdown"

# used_news（この回で紹介したニュース欄）の最終フォーマット保証を担う。
# ScriptGenerator は「## カテゴリ / ### [タイトル](URL)」形式のそれっぽい Markdown を
# 生成するだけでよく、フォーマットが厳密に正しいかどうかの検証・保証はしない。
# 最終的にフォーマットを保証するのは Publisher で、GCS への書き込みを始める前に
# ensure_valid! を呼ぶ（詳細は CLAUDE.md「used_news の表示フォーマット」参照）。
module UsedNewsFormatter
  module_function

  # used_news の期待フォーマット。パース失敗時に AI へ渡す整形指示
  # （文法の正は lib/internal/used_news_markdown.rb / CLAUDE.md）。
  FORMAT_SPEC = <<~SPEC
    ## <カテゴリ名>
    ### [<タイトル>](<link>)
       <1〜2文の短い要約>
       (<date> / <source>)
    ### [<次のタイトル>](<link>)
       ...

    ## <次のカテゴリ名>
    ### ...
  SPEC

  # fix_format.prompt.erb は format_spec/broken_content/output_path のローカル変数
  # のみを参照し、ScriptGenerator/Publisher いずれのインスタンスメソッドにも依存しない
  # ため、テンプレート描画用の context はこの専用の空オブジェクトで足りる。
  PROMPT_CONTEXT = Object.new.freeze

  # 前置き除去 → フォーマット検証 → 崩れていれば AI 修復、の順に整えて返す。
  # 修復後もフォーマットが直らなければ abort する（Publisher から呼ばれる想定なので、
  # ここで publish 全体を止める。中途半端な公開状態を作らないため）。
  # used_news が無い回（空文字列）は早期 return し、AI 呼び出し・abort を行わない。
  def ensure_valid!(text)
    cleaned = strip_preamble(text.to_s)
    return "" if cleaned.strip.empty?
    return cleaned if UsedNewsMarkdown.render(cleaned).ok

    warn "used news format invalid, attempting repair"
    repaired = repair(cleaned)
    return repaired if repaired

    abort "used news format is invalid and repair failed: publish aborted"
  end

  # 一覧本体より前の前置きを機械的に取り除く。本体は「## カテゴリ名」見出しから
  # 始まる構造（category_details 由来）なので、最初の「##」行を起点とみなす。
  def strip_preamble(used)
    lines = used.lines
    start = lines.each_index.find { |i| lines[i].strip.start_with?("##") }
    # 想定した構造が見つからなければそのまま返して人間が気づけるようにする
    return used unless start

    "#{lines[start..].join.strip}\n"
  end

  def repair(content)
    candidate = content
    ::Config.ai_agent.used_fix_max_retries.times do
      fixed = run_fix_cli(candidate)
      return nil unless fixed

      fixed = strip_preamble(fixed) # 修復 AI も前置きを足しうる
      return fixed if UsedNewsMarkdown.render(fixed).ok && preserves_urls?(content, fixed)

      candidate = fixed
    end
    nil
  end
  private_class_method :repair

  # 修復専用の非致命的な AI 呼び出し。tmp file に Write させ、Ruby 側が読んで返す
  # （stdout は前置き・コードフェンス等のノイズが混入しやすいため使わない）。
  # 失敗・書き忘れなら nil（ensure_valid! 側で最終的に abort するかどうかを判断する）。
  def run_fix_cli(broken_text)
    Dir.mktmpdir("used_news_formatter") do |dir|
      output_path = File.join(dir, "fixed.txt")
      prompt = TemplateRenderer.render("fix_format.prompt", PROMPT_CONTEXT,
        format_spec: FORMAT_SPEC, broken_content: broken_text, output_path: output_path)

      Internal::AiCli.run("repairing used news format", prompt,
        model_override: Internal::AiCli.model_for(:used_fix),
        effort_override: ::Config.ai_agent.used_fix_effort,
        fatal: false)

      next nil unless File.exist?(output_path)

      fixed = File.read(output_path).strip
      fixed.empty? ? nil : fixed
    end
  end
  private_class_method :run_fix_cli

  # 修復 AI が記事を捏造/欠落させていないことの機械的ガード。整形後の URL 集合が
  # 元の URL 集合と一致することを要求する（増減どちらも不採用）。
  def preserves_urls?(original, fixed)
    urls_in(original) == urls_in(fixed)
  end
  private_class_method :preserves_urls?

  def urls_in(text) = text.scan(%r{https?://[^\s)]+}).to_set
  private_class_method :urls_in
end
