# frozen_string_literal: true

require "fileutils"
require_relative "../slot"

# 直近に紹介したニュースの履歴を回ごとのファイルとして work/used_news_history/ に貯め、
# selector プロンプトに渡して回またぎの重複紹介を避けるためのモジュール。
module UsedNewsHistory
  module_function

  # 履歴ファイルを置くディレクトリ（回ごとに <episode_key>.txt を1ファイル）。
  # work_globs のホワイトリストに載らないので clean 非対象（回をまたぐ永続状態）。
  def dir(work_dir) = File.join(work_dir, "used_news_history")

  # 1 回分の used_news を履歴に取り込む。used_news_path が無ければ何もしない
  # （台本を作らずに confirm された回など）。link 行を落として <episode_key>.txt に
  # 書き、直近 keep_episodes 回だけ残して古い回を消す。同一 episode_key は上書き（冪等）。
  def record!(work_dir:, episode_key:, used_news_path:, keep_episodes:)
    return unless used_news_path && File.exist?(used_news_path)

    history_dir = dir(work_dir)
    FileUtils.mkdir_p(history_dir)
    write(File.join(history_dir, "#{episode_key}.txt"), strip_links(File.read(used_news_path)))
    prune(history_dir, keep_episodes)
  end

  # 直近 keep_episodes 回分の履歴を新しい順に連結して返す（selector プロンプト用）。
  # 履歴が無ければ空文字列（呼び出し側がセクションごと省略できる）。
  def render_for_prompt(work_dir, keep_episodes)
    recent_files(dir(work_dir), keep_episodes)
      .map { |path| File.read(path).strip }
      .reject(&:empty?)
      .join("\n\n")
  end

  # link を落とす。履歴の用途は selector プロンプトへの埋め込みで、URL は
  # ノイズにしかならない（重複判定はタイトル・要約・情報源で足りる）。
  # 新フォーマットは `### [タイトル](URL)` に URL が内包されるので `### タイトル` に畳む。
  # 旧フォーマット（独立した URL 行）が履歴に混じっていても落とせるよう、その除去も残す。
  # 除去で空いた行が連続しないよう、3 行以上の空行は 1 行に畳む。
  def strip_links(text)
    text
      .gsub(/^(###\s+)\[(.+)\]\(\S+\)\s*$/, '\1\2')
      .gsub(/^\s*https?:\S+\s*$\n?/, "")
      .gsub(/\n{3,}/, "\n\n")
  end
  private_class_method :strip_links

  # 履歴ディレクトリ内の <episode_key>.txt を、エピソードの時系列で新しい順に並べて
  # 上位 keep_episodes 件のパスを返す。並び順は (date_tag, slot の日内順)。
  def recent_files(history_dir, keep_episodes)
    return [] unless Dir.exist?(history_dir)

    Dir.glob(File.join(history_dir, "*.txt"))
      .sort_by { |path| episode_sort_key(File.basename(path, ".txt")) }
      .reverse
      .first(keep_episodes)
  end
  private_class_method :recent_files

  # 保持数を超えた古い回のファイルを消す。
  def prune(history_dir, keep_episodes)
    kept = recent_files(history_dir, keep_episodes)
    (Dir.glob(File.join(history_dir, "*.txt")) - kept).each { |path| File.delete(path) }
  end
  private_class_method :prune

  # episode_key（"<date_tag>_<slot>"）を [date_tag, slot の日内順] に分解する。
  # 未知形式のキーは末尾（最古扱い）へ寄せて、削除・並べ替えが壊れないようにする。
  def episode_sort_key(episode_key)
    date_tag, slot = episode_key.rpartition("_").values_at(0, 2)
    [date_tag, Slot.sort_key(slot)]
  rescue KeyError
    ["", -1]
  end
  private_class_method :episode_sort_key

  def write(path, content)
    tmp = "#{path}.tmp"
    File.write(tmp, content)
    File.rename(tmp, path)
  end
  private_class_method :write
end
