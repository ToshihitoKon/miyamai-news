# frozen_string_literal: true

module Internal
  # 台本生成側から音声合成側へ渡す 1 回分の台本一式を、R2 の handoff/<episode_key>/ に置く。
  # FILES が全部揃っていれば受け渡し済みとみなす。
  class Handoff
    PREFIX = "handoff"
    DONE_PREFIX = "handoff_done"

    # 名前 => R2 上のオブジェクト名。mark_done! はこの順に移す。
    FILES = { tts_script: "tts_script.txt", script: "script.txt", used_news: "used_news.txt" }.freeze

    NotFound = Class.new(StandardError)

    def initialize(storage:)
      @storage = storage
    end

    def exist?(episode_key) = FILES.values.all? { |object| @storage.exist?(key(PREFIX, episode_key, object)) }

    # handoff/ に台本一式が揃っている回。
    def pending_episode_keys
      objects_by_episode = @storage.list("#{PREFIX}/").filter_map do |object_key|
        _prefix, episode_key, object = object_key.split("/", 3)
        [episode_key, object] if object
      end.group_by(&:first)
      objects_by_episode.select { |_episode_key, pairs| (FILES.values - pairs.map(&:last)).empty? }.keys
    end

    # contents: FILES と同じキーを持つ Hash（値はファイル本文）。
    def upload!(episode_key, contents)
      FILES.each do |name, object|
        @storage.put(key(PREFIX, episode_key, object), contents.fetch(name), content_type: "text/plain; charset=utf-8")
      end
    end

    # paths: FILES と同じキーを持つ Hash（値は書き込み先のローカルパス）。
    def download!(episode_key, paths)
      raise NotFound, "handoff not found or incomplete: #{PREFIX}/#{episode_key}/" unless exist?(episode_key)

      FILES.each do |name, object|
        File.write(paths.fetch(name), @storage.get(key(PREFIX, episode_key, object)))
      end
    end

    # handoff/ に残っているものだけを handoff_done/ へ移し、移した数を返す。
    def mark_done!(episode_key)
      FILES.values.count do |object|
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
