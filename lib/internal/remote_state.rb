# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require_relative "object_storage"

module Internal
  # 実行をまたいで保持するパイプラインの内部状態（収集 window・フィードキャッシュ・紹介済み履歴）を
  # R2 の state/ プレフィックスと work_dir の間で同期する。正は R2 側で、work_dir は
  # checkout! で取り出した作業コピー。書き戻した時点の revision を state_revision に置き、
  # 作業コピーの取得元 revision と取り出した実行（owner）を work_dir/.state_base_revision に記録する。
  class RemoteState
    PREFIX = "state/"
    REVISION_KEY = "state_revision"
    BASE_REVISION_FILE = ".state_base_revision"

    # work_dir からの相対 glob。
    TRACKED_GLOBS = %w[last_fetch.json feed_cache.json feed_cache/*.json used_news_history/*.txt].freeze

    Missing = Class.new(StandardError)
    Conflict = Class.new(StandardError)
    NotCheckedOut = Class.new(StandardError)

    def initialize(storage:, work_dir:)
      @storage = storage
      @work_dir = work_dir
    end

    # 作業コピーを用意する。未完了の実行が残した作業コピーがあり、その取得元 revision が
    # R2 と同じなら引き継ぐ（:resumed）。無ければ R2 から取得する（:pulled）。
    def checkout!(owner:)
      remote = remote_revision
      raise Missing, "#{REVISION_KEY} not found in R2; the pipeline state is incomplete (re-seed it)" if remote.nil? && !@storage.list(PREFIX).empty?

      base = base_revision
      return pull!(remote, owner) if base.nil?
      raise Conflict, conflict_message if base != remote.to_s

      :resumed
    end

    # 作業コピーを取り出した実行の owner（checkout! に渡した値）。作業コピーが無ければ nil。
    def checked_out_by = read_base&.fetch("owner")

    # 何も書き戻さずに作業コピーを手放す（次の checkout! は R2 から取り直す）。
    def release!
      FileUtils.rm_f(base_revision_path)
    end

    # 書き戻す前に、作業コピーの取得後に誰も R2 を更新していないことを確かめる。
    def ensure_current!
      base = base_revision
      raise NotCheckedOut, "pipeline state is not checked out in #{@work_dir}" if base.nil?

      remote = remote_revision
      raise Conflict, conflict_message if remote.nil? || base != remote
    end

    # 作業コピーで R2 を置き換え（作業コピーに無い R2 のキーは消す）、revision を進める。
    def push!
      ensure_current!

      local_keys = upload_local_files
      (@storage.list(PREFIX) - local_keys).each { |key| @storage.delete(key) }
      @storage.put(REVISION_KEY, new_revision, content_type: "text/plain")
      release!
      local_keys.size
    end

    # R2 側が空のときだけ、work_dir の対象ファイルをそのまま R2 へ置く（初回移行用）。
    def seed!
      raise ArgumentError, "pipeline state already exists under #{PREFIX} in R2" unless @storage.list(PREFIX).empty?

      count = upload_local_files.size
      @storage.put(REVISION_KEY, new_revision, content_type: "text/plain")
      count
    end

    def local_files
      TRACKED_GLOBS.flat_map { |pat| Dir.glob(File.join(@work_dir, pat)) }.sort
    end

    private

    # R2 の状態で work_dir の対象ファイルを置き換える（R2 に無いローカルのファイルは消す）。
    def pull!(remote, owner)
      keys = @storage.list(PREFIX)
      raise Missing, "no pipeline state found under #{PREFIX} in R2 (seed it with scripts/seed_remote_state.rb)" if keys.empty?

      FileUtils.rm_f(local_files)
      keys.each do |key|
        path = File.join(@work_dir, key.delete_prefix(PREFIX))
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, @storage.get(key))
      end
      FileUtils.mkdir_p(@work_dir)
      File.write(base_revision_path, JSON.generate("revision" => remote.to_s, "owner" => owner))
      :pulled
    end

    def conflict_message
      "pipeline state in R2 was updated by another run after #{@work_dir} checked it out. " \
        "Discard the unfinished local run with --clean and run again."
    end

    def remote_revision
      @storage.get(REVISION_KEY)
    rescue ObjectStorage::ObjectNotFound
      nil
    end

    def base_revision = read_base&.fetch("revision")
    def base_revision_path = File.join(@work_dir, BASE_REVISION_FILE)

    def read_base
      File.exist?(base_revision_path) ? JSON.parse(File.read(base_revision_path)) : nil
    end

    def new_revision = "#{Time.now.utc.iso8601(6)}-#{SecureRandom.hex(4)}"

    def upload_local_files
      local_files.map do |path|
        key = PREFIX + path.delete_prefix("#{@work_dir}/")
        @storage.put_file(key, path, content_type: content_type_for(path))
        key
      end
    end

    def content_type_for(path)
      File.extname(path) == ".json" ? "application/json" : "text/plain; charset=utf-8"
    end
  end
end
