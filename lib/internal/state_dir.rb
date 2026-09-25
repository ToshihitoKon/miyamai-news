# frozen_string_literal: true

require "fileutils"

# 実行をまたいで保持するパイプラインの内部状態を置くディレクトリ（work/state/）。
# 中身はそのまま R2 の state/ と同期される。
module StateDir
  module_function

  NAME = "state"

  # 内部状態を work/ 直下に置いていた頃のエントリ名。
  LEGACY_ENTRIES = %w[last_fetch.json feed_cache.json feed_cache used_news_history].freeze

  def path(work_dir) = File.join(work_dir, NAME)

  def legacy_entries(work_dir)
    LEGACY_ENTRIES.map { |name| File.join(work_dir, name) }.select { |entry| File.exist?(entry) }
  end

  # work/ 直下に残っている内部状態を work/state/ へ移し、移したエントリを返す。
  # 移動先に同名のものがあれば何も移さずに中断する。
  def migrate_legacy!(work_dir)
    entries = legacy_entries(work_dir)
    conflicts = entries.select { |entry| File.exist?(File.join(path(work_dir), File.basename(entry))) }
    abort "#{conflicts.join(', ')} already exist in #{path(work_dir)}; resolve them manually" unless conflicts.empty?

    FileUtils.mkdir_p(path(work_dir))
    entries.each { |entry| FileUtils.mv(entry, path(work_dir)) }
    entries
  end
end
