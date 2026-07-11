# frozen_string_literal: true

require "erb"

# templates/ 以下の ERB テンプレート（プロンプト *.prompt.erb と HTML/XML *.erb）を
# 読み込み、呼び出し側の binding で描画する。
#
# 描画時に値を引数で渡さず binding を受け取るのは、呼び出し側のローカル変数・
# インスタンス変数をそのままテンプレートの <%= ... %> から参照させるため。
module TemplateRenderer
  # templates/ はプロジェクトルート（lib/ の一つ上）に置く。
  DIR = File.join(File.expand_path("..", __dir__), "templates")

  class << self
    # name は拡張子 .erb を除いたテンプレート名（例: "writer.prompt", "index.html"）。
    # bind に渡した binding のスコープでテンプレートを評価する。
    def render(name, bind)
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
      raise ArgumentError, "テンプレートがありません: #{path}" unless File.exist?(path)

      # trim_mode "-" は <%- -%> を書いたときだけ前後の空白を削る。通常の
      # <%= %> には影響しないので、プロンプトも HTML/XML も同じ設定で扱える。
      ERB.new(File.read(path), trim_mode: "-")
    end

    def cache = @cache ||= {}
  end
end
