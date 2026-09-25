# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "state_dir"

# 1 回分の収集結果（候補ニュース一覧）と、その収集時刻（at）を
# work/state/news_snapshots/<episode_key>.json に残す。
module NewsSnapshot
  module_function

  Snapshot = Struct.new(:news, :at, keyword_init: true)

  def dir(work_dir) = File.join(StateDir.path(work_dir), "news_snapshots")
  def path(work_dir, episode_key) = File.join(dir(work_dir), "#{episode_key}.json")

  def save!(work_dir:, episode_key:, news:, at:)
    FileUtils.mkdir_p(dir(work_dir))
    file_path = path(work_dir, episode_key)
    tmp = "#{file_path}.tmp"
    File.write(tmp, JSON.generate("news" => news, "at" => at.iso8601))
    File.rename(tmp, file_path)
  end

  # 無ければ nil。
  def load(work_dir, episode_key)
    file_path = path(work_dir, episode_key)
    return unless File.exist?(file_path)

    data = JSON.parse(File.read(file_path))
    Snapshot.new(news: data.fetch("news"), at: Time.iso8601(data.fetch("at")))
  end

  # keep_keys に含まれない回のスナップショットを消す。
  def retain!(work_dir:, keep_keys:)
    Dir.glob(File.join(dir(work_dir), "*.json")).each do |file_path|
      File.delete(file_path) unless keep_keys.include?(File.basename(file_path, ".json"))
    end
  end
end
