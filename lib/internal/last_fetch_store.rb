# frozen_string_literal: true

require "fileutils"
require "time"
require "json"
require_relative "../slot"
require_relative "state_dir"

# 収集 window を確定した直近の回（commits）を work/state/last_fetch.json に永続化するモジュール。
# 確定は episode_key 単位の { "episode" => "<date_tag>_<slot>", "at" => その回の収集時刻 } で、
# 新しい回から KEEP_COMMITS 件まで残す。ある回の収集 window の起点は、その回より前の確定の
# うち最新のものの at。
module LastFetchStore
  module_function

  KEEP_COMMITS = 3
  LEGACY_EPISODE = "legacy"

  class OlderEpisodeError < StandardError; end

  def path(work_dir) = File.join(StateDir.path(work_dir), "last_fetch.json")

  # 確定履歴（新しい回から順）。
  def commits(work_dir) = sort_newest_first(load(work_dir)["commits"])

  def latest_commit(work_dir) = commits(work_dir).first

  # episode_key の回の収集 window の起点。前の確定が無ければ nil。最新の確定より古い回
  # （最新の確定の回そのものは除く）は後の回と収集範囲が重なるので OlderEpisodeError。
  def since_for(work_dir, episode_key)
    ensure_not_older!(work_dir, episode_key)
    previous = commits(work_dir).find { |c| c["episode"] != episode_key }
    previous && Time.iso8601(previous["at"])
  end

  # episode_key の回を確定する。同じ回の確定があれば置き換える（作り直した回の確定を
  # 二重に積まない）。
  def commit!(work_dir:, episode_key:, at:)
    ensure_not_older!(work_dir, episode_key)
    others = commits(work_dir).reject { |c| c["episode"] == episode_key }
    write(work_dir, "commits" => [{ "episode" => episode_key, "at" => at.iso8601 }, *others].first(KEEP_COMMITS))
  end

  def ensure_not_older!(work_dir, episode_key)
    latest = latest_commit(work_dir)
    return if latest.nil? || latest["episode"] == episode_key
    return if (sort_key(episode_key) <=> sort_key(latest["episode"])) == 1

    raise OlderEpisodeError, "#{episode_key} is older than the latest committed episode #{latest['episode']}; " \
                             "its news cannot be collected again because the window overlaps later episodes"
  end
  private_class_method :ensure_not_older!

  # 確定履歴導入前の形式（confirmed_at だけ）は、起点として効く最古扱いの確定に読み替える。
  def load(work_dir)
    data = read_raw(work_dir) || {}
    return { "commits" => data["commits"] } if data["commits"].is_a?(Array)
    return { "commits" => [] } unless data["confirmed_at"]

    { "commits" => [{ "episode" => LEGACY_EPISODE, "at" => data["confirmed_at"] }] }
  end
  private_class_method :load

  def sort_newest_first(commits) = commits.sort_by { |c| sort_key(c["episode"]) }.reverse

  # 未知の episode_key（LEGACY_EPISODE を含む）は最古扱い。
  def sort_key(episode_key) = Slot.sort_key_from_filename(episode_key) || ["", -1]
  private_class_method :sort_key

  def write(work_dir, data)
    file_path = path(work_dir)
    FileUtils.mkdir_p(File.dirname(file_path))
    tmp = "#{file_path}.tmp"
    File.write(tmp, JSON.generate(data))
    File.rename(tmp, file_path)
  end
  private_class_method :write

  # パース不能な壊れたファイルは空扱いで返す。valid JSON だが Hash でなければ abort する。
  def read_raw(work_dir)
    file_path = path(work_dir)
    return unless File.exist?(file_path)

    data = JSON.parse(File.read(file_path))
    unless data.is_a?(Hash)
      abort("#{file_path} is valid JSON but not an object; refusing to overwrite it with " \
            "defaults. Inspect/repair it manually (or with AI assistance) and re-run.")
    end

    data
  rescue JSON::ParserError
    nil
  end
  private_class_method :read_raw
end
