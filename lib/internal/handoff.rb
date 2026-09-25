# frozen_string_literal: true

require "json"
require "time"

module Internal
  # 台本生成側から音声合成側へ渡す 1 回分の台本一式を、R2 の handoff/<episode_key>/ に置く。
  # manifest.json の有無で「一式が揃っているか」を判定する。
  class Handoff
    PREFIX = "handoff"
    DONE_PREFIX = "handoff_done"
    MANIFEST = "manifest.json"

    # 名前 => R2 上のオブジェクト名
    FILES = { tts_script: "tts_script.txt", script: "script.txt", used_news: "used_news.txt" }.freeze

    NotFound = Class.new(StandardError)

    def initialize(storage:)
      @storage = storage
    end

    def exist?(episode_key) = @storage.exist?(key(PREFIX, episode_key, MANIFEST))

    # contents: FILES と同じキーを持つ Hash（値はファイル本文）。commit! するまでは exist? が false のまま。
    def upload_files!(episode_key, contents)
      FILES.each do |name, object|
        @storage.put(key(PREFIX, episode_key, object), contents.fetch(name), content_type: "text/plain; charset=utf-8")
      end
    end

    def commit!(episode_key)
      manifest = { episode_key: episode_key, files: FILES.values, created_at: Time.now.iso8601 }
      @storage.put(key(PREFIX, episode_key, MANIFEST), JSON.generate(manifest), content_type: "application/json")
    end

    # paths: FILES と同じキーを持つ Hash（値は書き込み先のローカルパス）。
    def download!(episode_key, paths)
      raise NotFound, "handoff not found: #{key(PREFIX, episode_key, MANIFEST)}" unless exist?(episode_key)

      FILES.each do |name, object|
        File.write(paths.fetch(name), @storage.get(key(PREFIX, episode_key, object)))
      end
    end

    # handoff/ に残っているものだけを handoff_done/ へ移し、移した数を返す。
    def mark_done!(episode_key)
      [MANIFEST, *FILES.values].count do |object|
        from = key(PREFIX, episode_key, object)
        next false unless @storage.exist?(from)

        @storage.move(from, key(DONE_PREFIX, episode_key, object))
        true
      end
    end

    private

    def key(prefix, episode_key, object) = "#{prefix}/#{episode_key}/#{object}"
  end
end
