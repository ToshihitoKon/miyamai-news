# frozen_string_literal: true

require "erb"

# templates/ 以下の ERB テンプレート（プロンプト *.prompt.erb と HTML/XML *.erb）を
# 読み込んで描画する。
#
# context オブジェクトのスコープで評価するので、テンプレートは context の
# インスタンス変数（@title など）や private メソッド（h, date_with_slot など）を
# そのまま呼べる。テンプレート固有の値は locals ハッシュで明示的に渡す。
module TemplateRenderer
  DIR = File.join(File.expand_path("../..", __dir__), "templates")

  class << self
    # name は拡張子を除いたテンプレート名（例: "writer.prompt", "index.html"）。
    def render(name, context, locals = {})
      bind = context.instance_eval { binding }
      locals.each { |key, value| bind.local_variable_set(key, value) }
      erb(name).result(bind)
    end

    private

    # コンパイル済み ERB をテンプレート名でキャッシュする。同一プロセス内で
    # 同じテンプレートを何度も描画しても、ファイル読み込みと構文解析は 1 回で済む。
    def erb(name)
      cache[name] ||= build_erb(name)
    end

    def build_erb(name)
      path = File.join(DIR, "#{name}.erb")
      raise ArgumentError, "template not found: #{path}" unless File.exist?(path)

      # trim_mode "-" は <%- -%> を書いたときだけ前後の空白を削る。通常の
      # <%= %> には影響しないので、プロンプトも HTML/XML も同じ設定で扱える。
      ERB.new(File.read(path), trim_mode: "-")
    end

    def cache = @cache ||= {}
  end
end
