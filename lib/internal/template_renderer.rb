# frozen_string_literal: true

require "erb"

# templates/ 以下の ERB テンプレート（プロンプト *.prompt.erb と HTML/XML *.erb）を
# 読み込んで描画する。
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

    # コンパイル済み ERB をテンプレート名でキャッシュする。
    def erb(name)
      cache[name] ||= build_erb(name)
    end

    def build_erb(name)
      path = File.join(DIR, "#{name}.erb")
      raise ArgumentError, "template not found: #{path}" unless File.exist?(path)

      ERB.new(File.read(path), trim_mode: "-")
    end

    def cache = @cache ||= {}
  end
end
