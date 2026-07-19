# frozen_string_literal: true

require "time"
require "json"

# 収集 window の起点を work/last_fetch.json に永続化するモジュール。前回 pending の
# 確定/ロールバックを人間に尋ねる .resolve_pending! も持つ（状態を握る当のモジュールが
# 対話込みの解決まで面倒を見た方が凝集度が高い）。状態はすべて JSON 側にあり、
# インスタンス状態は持たない（work_dir を渡すだけのモジュール関数の集まり）。
#
# JSON の4キー: confirmed_at(確定済みの収集window起点。次回 since に使う) /
# pending_at(直近実行の未確認の到達時刻) / rollback_at(直前の confirm!/rollback! で
# 失われた値を退避する1段の Undo バッファ) / last_op(rollback_at が confirm/discard
# どちらの Undo 用かを示す)。
#
# 収集 window の確定ルール・resolve_pending! の既定動作は CLAUDE.md
# 「LastFetchStore / 収集window」を参照。
module LastFetchStore
  module_function

  def path(work_dir) = File.join(work_dir, "last_fetch.json")

  # confirmed_at/pending_at/rollback_at/last_op の4キーを保証して返す（無ければ nil）。
  def load(work_dir)
    return read_data(work_dir) if File.exist?(path(work_dir))

    default_data
  end

  # 確定済みの収集window起点。無い/壊れていれば nil。
  def confirmed_at(work_dir) = parse_time(load(work_dir)["confirmed_at"])

  # 未確認の到達時刻。無い/壊れていれば nil。
  def pending_at(work_dir) = parse_time(load(work_dir)["pending_at"])

  # .restore! で巻き戻せる状態があるか。無ければ nil。
  def restorable?(work_dir) = !load(work_dir)["last_op"].nil?

  # 新規収集が発生した実行の完了時に呼ぶ。confirmed_at は動かさず、pending_at を at に
  # 進める。人間の操作ではない（Undo 対象にしない）ので Undo バッファはクリアする。
  def mark_pending!(work_dir:, at:)
    write(work_dir, load(work_dir).merge("pending_at" => at.iso8601, "rollback_at" => nil, "last_op" => nil))
  end

  # pending_at を confirmed_at へ昇格し、pending_at をクリアする。.restore! で
  # 巻き戻せるよう、昇格前の confirmed_at を rollback_at へ退避し last_op を confirm にする。
  # pending_at が無ければ何もしない（冪等）。
  def confirm!(work_dir:)
    data = load(work_dir)
    return unless data["pending_at"]

    write(work_dir, data.merge(
      "confirmed_at" => data["pending_at"], "pending_at" => nil,
      "rollback_at" => data["confirmed_at"], "last_op" => "confirm"
    ))
  end

  # pending_at を捨てる（confirmed_at は変えない）。誤って rollback しても .restore! で
  # 復旧できるよう、捨てた値を rollback_at に退避する。pending_at が無ければ何もしない。
  def rollback!(work_dir:)
    data = load(work_dir)
    return unless data["pending_at"]

    write(work_dir, data.merge("pending_at" => nil, "rollback_at" => data["pending_at"], "last_op" => "discard"))
  end

  # 直前の人間操作（confirm!/rollback!）を1段だけ巻き戻す。last_op で分岐し、
  # 巻き戻したら Undo バッファをクリアする（Redo はしない、冪等）。
  def restore!(work_dir:)
    data = load(work_dir)
    case data["last_op"]
    when "confirm"
      write(work_dir, data.merge(
        "pending_at" => data["confirmed_at"], "confirmed_at" => data["rollback_at"],
        "rollback_at" => nil, "last_op" => nil
      ))
    when "discard"
      write(work_dir, data.merge("pending_at" => data["rollback_at"], "rollback_at" => nil, "last_op" => nil))
    end
  end

  # publish 完了時に呼ぶ。pending を経由せず confirmed_at を即座に at へ確定する
  # （公開自体が確定行為のため）。
  def confirm_immediately!(work_dir:, at:)
    write(work_dir, load(work_dir).merge("confirmed_at" => at.iso8601, "pending_at" => nil, "rollback_at" => nil, "last_op" => nil))
  end

  # 前回 pending が残っていれば確定/ロールバックを尋ねて解決する（無ければ何もしない）。
  # auto_confirm 時は対話せず自動確定する。既定(Enter/N)はロールバック側
  # （安全側の既定。理由は CLAUDE.md 参照）。
  def resolve_pending!(work_dir:, auto_confirm: false)
    pending = pending_at(work_dir)
    return unless pending

    if auto_confirm
      confirm!(work_dir: work_dir)
      warn "auto-confirmed pending fetch window: #{pending}"
      return
    end

    print "The previous fetch window is unconfirmed (#{pending}). Confirm it? Answering no rolls it back. [y/N]: "
    if $stdin.gets&.strip&.match?(/\Ay\z/i)
      confirm!(work_dir: work_dir)
      warn "confirmed pending fetch window: #{pending}"
    else
      rollback!(work_dir: work_dir)
      warn "rolled back pending fetch window (kept confirmed_at)"
    end
  end

  def write(work_dir, data)
    File.write(path(work_dir), JSON.generate(data))
  end
  private_class_method :write

  def parse_time(raw)
    raw && Time.iso8601(raw)
  rescue ArgumentError
    nil
  end
  private_class_method :parse_time

  # last_fetch.json（存在する前提で呼ぶ）を読み、last_op 導入前に書かれたファイルに
  # 欠けているキーを default で補って返す。パース不能な壊れたファイルは空扱いで返す
  # （安全側にフォールバックする）。
  def read_data(work_dir)
    default_data.merge(JSON.parse(File.read(path(work_dir))))
  rescue JSON::ParserError
    default_data
  end
  private_class_method :read_data

  def default_data = { "confirmed_at" => nil, "pending_at" => nil, "rollback_at" => nil, "last_op" => nil }
  private_class_method :default_data
end
