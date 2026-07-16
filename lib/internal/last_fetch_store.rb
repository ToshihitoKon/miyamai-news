# frozen_string_literal: true

require "time"
require "json"

# 収集 window の起点を work/last_fetch.json に永続化する。ScriptGenerator の
# 収集ロジックとは無関係な、状態遷移と読み書きだけに責務を絞ったクラス。
#
# 収集 window は「実行が完了したら即確定」ではなく、人間が成果物（facts/台本/mp3）を
# 確認して次に進んでよいと判断した時点で確定する（publish だけは公開自体が確定行為
# なので例外、#confirm_immediately! を使う）。そのため状態は3つ持つ。
#   confirmed_at: 確定済みの収集window起点。ScriptGenerator が収集の since に使う値。
#   pending_at:   直近の実行で新規収集が起きたが、まだ確認していない時刻。
#   rollback_at:  pending_at がセットされる直前の confirmed_at（監査用）。
class LastFetchStore
  def initialize(work_dir:)
    @work_dir = work_dir
  end

  def path = File.join(@work_dir, "last_fetch.json")

  # 旧形式(単一 ISO8601 時刻、mode 非依存)の記録ファイル。存在すれば読み込み時に
  # 自動移行する。
  def legacy_path = File.join(@work_dir, "last_fetch.txt")

  # confirmed_at/pending_at/rollback_at の3キーを保証して返す（無ければ nil）。
  def load
    return migrate! if File.exist?(path)

    migrate_legacy || default_data
  end

  # 確定済みの収集window起点。無い/壊れていれば nil。
  def confirmed_at = parse_time(load["confirmed_at"])

  # 未確認の到達時刻。無い/壊れていれば nil。
  def pending_at = parse_time(load["pending_at"])

  # 新規収集が発生した実行の完了時に呼ぶ。confirmed_at は動かさず、pending_at を at に
  # 進め、rollback_at に更新前の confirmed_at を退避する。
  def mark_pending!(at:)
    data = load
    write(data.merge("pending_at" => at.iso8601, "rollback_at" => data["confirmed_at"]))
  end

  # pending_at を confirmed_at へ昇格し、pending_at/rollback_at をクリアする。
  # pending_at が無ければ何もしない（冪等）。
  def confirm!
    data = load
    return unless data["pending_at"]

    write(data.merge("confirmed_at" => data["pending_at"], "pending_at" => nil, "rollback_at" => nil))
  end

  # pending_at/rollback_at をクリアするだけ。confirmed_at は現状維持のまま変えない
  # （そもそも rollback_at と同じ値のはずなので、値を書き戻す必要がない）。
  def rollback!
    data = load
    write(data.merge("pending_at" => nil, "rollback_at" => nil))
  end

  # publish 完了時に呼ぶ。pending を経由せず confirmed_at を即座に at へ確定する
  # （公開自体が確定行為なので対話を挟まない）。
  def confirm_immediately!(at:)
    write("confirmed_at" => at.iso8601, "pending_at" => nil, "rollback_at" => nil)
  end

  private

  def write(data)
    File.write(path, JSON.generate(data))
  end

  def parse_time(raw)
    raw && Time.iso8601(raw)
  rescue ArgumentError
    nil
  end

  # last_fetch.json（存在する前提で呼ぶ）を新形式(confirmed_at/pending_at/rollback_at)
  # で返す。旧 mode 別キー形式が残っていれば自動移行してから返す。パース不能な壊れた
  # ファイルは移行せず残し、空扱いで返す（安全側にフォールバックする）。
  def migrate!
    data = JSON.parse(File.read(path))
    return data if new_format?(data)

    migrated = default_data.merge("confirmed_at" => most_advanced(data))
    write(migrated)
    migrated
  rescue JSON::ParserError
    default_data
  end

  def default_data = { "confirmed_at" => nil, "pending_at" => nil, "rollback_at" => nil }

  def new_format?(data) = %w[confirmed_at pending_at rollback_at].any? { |k| data.key?(k) }

  # 旧 mode 別キー形式（digest/synthesize/publish）から、最も進んだ値を採る。
  # 収集window の起点は遅い方が安全（記事の取りこぼしを避けられる）。
  def most_advanced(data)
    %w[publish synthesize digest].each { |mode| return data[mode] if data[mode] }
    nil
  end

  def migrate_legacy
    return nil unless File.exist?(legacy_path)

    at = Time.iso8601(File.read(legacy_path).strip)
    data = default_data.merge("confirmed_at" => at.iso8601)
    write(data)
    File.delete(legacy_path)
    data
  rescue ArgumentError
    nil # 壊れた旧ファイルは移行せず残す（呼び出し側で安全側にフォールバックする）
  end
end
