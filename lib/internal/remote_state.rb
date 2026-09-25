# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require_relative "object_storage"
require_relative "state_dir"

module Internal
  # 実行をまたいで保持するパイプラインの内部状態（work/state/）を R2 の state/ プレフィックスと
  # 同期する。正は R2 側で、work/state/ は
  # checkout! で取り出した作業コピー。書き戻した時点の revision を state_revision に置き、
  # 作業コピーの取得元 revision と取り出した実行（owner）を work_dir/.state_base_revision に記録する。
  class RemoteState
    PREFIX = "#{StateDir::NAME}/".freeze
    REVISION_KEY = "state_revision"
    BASE_REVISION_FILE = ".state_base_revision"

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

    # revision を進めて作業コピーの取得元にも記録してから、作業コピーで R2 を置き換える
    # （作業コピーに無い R2 のキーは消す）。
    def push!
      ensure_current!

      revision = new_revision
      @storage.put(REVISION_KEY, revision, content_type: "text/plain")
      write_base(revision, checked_out_by)
      remove_partial_writes
      @storage.sync_up(prefix: PREFIX, root: @work_dir)
      release!
    end

    # R2 側が空のときだけ、work/state/ をそのまま R2 へ置く（初回移行用）。
    def seed!
      raise ArgumentError, "pipeline state already exists under #{PREFIX} in R2" unless @storage.list(PREFIX).empty?

      remove_partial_writes
      @storage.sync_up(prefix: PREFIX, root: @work_dir)
      @storage.put(REVISION_KEY, new_revision, content_type: "text/plain")
    end

    def local_files
      Dir.glob(File.join(StateDir.path(@work_dir), "**", "*")).select { |path| File.file?(path) }.sort
    end

    private

    # R2 の状態で work/state/ を置き換える。
    def pull!(remote, owner)
      raise Missing, "no pipeline state found under #{PREFIX} in R2 (seed it with scripts/seed_remote_state.rb)" if @storage.list(PREFIX).empty?

      @storage.sync_down(prefix: PREFIX, root: @work_dir)
      write_base(remote.to_s, owner)
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

    def write_base(revision, owner)
      File.write(base_revision_path, JSON.generate("revision" => revision, "owner" => owner))
    end

    def read_base
      File.exist?(base_revision_path) ? JSON.parse(File.read(base_revision_path)) : nil
    end

    def new_revision = "#{Time.now.utc.iso8601(6)}-#{SecureRandom.hex(4)}"

    # tmp に書いてから rename する途中で落ちた書き込みの残骸。
    def remove_partial_writes
      FileUtils.rm_f(Dir.glob(File.join(StateDir.path(@work_dir), "**", "*.tmp")))
    end
  end
end
