# frozen_string_literal: true

require "time"
require "json"
require_relative "config"

# 収集 window の起点（各 pipeline.mode が前回到達した時刻）を work/last_fetch.json に
# 永続化する。ScriptGenerator の収集ロジックとは無関係な、単なる記録の読み書きに
# 責務を絞ったクラス。
class LastFetchStore
  def initialize(work_dir:)
    @work_dir = work_dir
  end

  def path = File.join(@work_dir, "last_fetch.json")

  # 旧形式(単一 ISO8601 時刻、mode 非依存)の記録ファイル。存在すれば読み込み時に
  # 自動移行する。
  def legacy_path = File.join(@work_dir, "last_fetch.txt")

  # mode 別の到達時刻を読み込む。last_fetch.json が無く旧 last_fetch.txt が残っていれば
  # 全 mode キーへ同じ時刻をコピーして自動移行する。
  def load
    return JSON.parse(File.read(path)) if File.exist?(path)

    migrate_legacy || {}
  end

  # mode に到達したことを at で記録する。到達した mode 以下の全ての下位 mode も
  # 同時に同じ時刻へ進める。例えば publish 到達時は digest/synthesize/publish の
  # 3キー全てを更新する。上位 mode を回した後に下位 mode 単体を回すと、既に処理済みの
  # 記事が選定 AI の対象に不要に再度上がってしまうため、これを避ける。
  def record_reached!(mode:, at:)
    data = load
    reached_order = Config::MODE_ORDER.fetch(mode)
    Config::MODE_ORDER.each { |m, order| data[m] = at.iso8601 if order <= reached_order }
    File.write(path, JSON.generate(data))
  end

  private

  def migrate_legacy
    return nil unless File.exist?(legacy_path)

    at = Time.iso8601(File.read(legacy_path).strip)
    data = Config::MODE_ORDER.keys.to_h { |m| [m, at.iso8601] }
    File.write(path, JSON.generate(data))
    File.delete(legacy_path)
    data
  rescue ArgumentError
    nil # 壊れた旧ファイルは移行せず残す（呼び出し側で安全側にフォールバックする）
  end
end
