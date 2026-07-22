# frozen_string_literal: true

require "time"
require "json"

# 収集 window の起点を work/last_fetch.json に永続化するモジュール。前回 pending の
# 確定/ロールバックを人間に尋ねる .resolve_pending! も持つ（状態を握る当のモジュールが
# 対話込みの解決まで面倒を見た方が凝集度が高い）。状態はすべて JSON 側にあり、
# インスタンス状態は持たない（work_dir を渡すだけのモジュール関数の集まり）。
#
# JSON のキー: confirmed_at(確定済みの収集window起点。次回 since に使う) /
# pending_at(直近実行の未確認の到達時刻) / pending_episode(pending_at の回の episode_key。
# confirm 時に紹介済みニュース履歴へ追記する回を特定するため保持する) / rollback_at(直前の
# confirm!/rollback! で失われた値を退避する1段の Undo バッファ) / last_op(rollback_at が
# confirm/discard どちらの Undo 用かを示す)。
#
# 収集 window の確定ルール・resolve_pending! の既定動作は CLAUDE.md
# 「LastFetchStore / 収集window」を参照。
module LastFetchStore
  module_function

  def path(work_dir) = File.join(work_dir, "last_fetch.json")

  # 全キー（冒頭コメント参照）を保証して返す（欠けているキーは nil で補う）。
  def load(work_dir)
    return read_data(work_dir) if File.exist?(path(work_dir))

    default_data
  end

  # 確定済みの収集window起点。無い/壊れていれば nil。
  def confirmed_at(work_dir) = parse_time(load(work_dir)["confirmed_at"])

  # 未確認の到達時刻。無い/壊れていれば nil。
  def pending_at(work_dir) = parse_time(load(work_dir)["pending_at"])

  # pending_at の回の episode_key（履歴追記対象の特定用）。無ければ nil。
  def pending_episode(work_dir) = load(work_dir)["pending_episode"]

  # .restore! で巻き戻せる状態があるか。無ければ nil。
  def restorable?(work_dir) = !load(work_dir)["last_op"].nil?

  # 新規収集が発生した実行の完了時に呼ぶ。confirmed_at は動かさず、pending_at を at に
  # 進める。episode_key はこの回の紹介済みニュース履歴を confirm 時に追記するため保持する。
  # 人間の操作ではない（Undo 対象にしない）ので Undo バッファはクリアする。
  def mark_pending!(work_dir:, at:, episode_key: nil)
    write(work_dir, load(work_dir).merge(
      "pending_at" => at.iso8601, "pending_episode" => episode_key,
      "rollback_at" => nil, "last_op" => nil
    ))
  end

  # pending_at を confirmed_at へ昇格し、pending_at をクリアする。.restore! で
  # 巻き戻せるよう、昇格前の confirmed_at を rollback_at へ退避し last_op を confirm にする。
  # 確定した回の episode_key を返す（呼び出し側が紹介済みニュース履歴へ追記するのに使う）。
  # pending_at が無ければ何もせず nil を返す（冪等）。
  def confirm!(work_dir:)
    data = load(work_dir)
    return unless data["pending_at"]

    episode_key = data["pending_episode"]
    write(work_dir, data.merge(
      "confirmed_at" => data["pending_at"], "pending_at" => nil, "pending_episode" => nil,
      "rollback_at" => data["confirmed_at"], "last_op" => "confirm"
    ))
    episode_key
  end

  # pending_at を捨てる（confirmed_at は変えない）。誤って rollback しても .restore! で
  # 復旧できるよう、捨てた値を rollback_at に退避する。pending_at が無ければ何もしない。
  # 破棄した回は履歴に残さないので pending_episode もクリアする（restore! では復元しない
  # 割り切り。復元したいなら work/ に残る used ファイルから手動で追記する）。
  def rollback!(work_dir:)
    data = load(work_dir)
    return unless data["pending_at"]

    write(work_dir, data.merge(
      "pending_at" => nil, "pending_episode" => nil,
      "rollback_at" => data["pending_at"], "last_op" => "discard"
    ))
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
  # （公開自体が確定行為のため）。この回の履歴追記は呼び出し側が episode から直接行うので
  # pending_episode は残さずクリアする。
  def confirm_immediately!(work_dir:, at:)
    write(work_dir, load(work_dir).merge(
      "confirmed_at" => at.iso8601, "pending_at" => nil, "pending_episode" => nil,
      "rollback_at" => nil, "last_op" => nil
    ))
  end

  # 前回 pending が残っていれば確定/ロールバックを尋ねて解決する（無ければ何もしない）。
  # auto_confirm 時は対話せず自動確定する。既定(Enter/N)はロールバック側
  # （安全側の既定。理由は CLAUDE.md 参照）。
  # 確定した場合はその回の episode_key を返す（呼び出し側が紹介済みニュース履歴へ追記する）。
  # ロールバック・何もしない場合は nil を返す。
  def resolve_pending!(work_dir:, auto_confirm: false)
    pending = pending_at(work_dir)
    return unless pending

    if auto_confirm
      episode_key = confirm!(work_dir: work_dir)
      warn "auto-confirmed pending fetch window: #{pending}"
      return episode_key
    end

    print "The previous fetch window is unconfirmed (#{pending}). Confirm it? Answering no rolls it back. [y/N]: "
    if $stdin.gets&.strip&.match?(/\Ay\z/i)
      episode_key = confirm!(work_dir: work_dir)
      warn "confirmed pending fetch window: #{pending}"
      episode_key
    else
      rollback!(work_dir: work_dir)
      warn "rolled back pending fetch window (kept confirmed_at)"
      nil
    end
  end

  def write(work_dir, data)
    file_path = path(work_dir)
    tmp = "#{file_path}.tmp"
    File.write(tmp, JSON.generate(data))
    File.rename(tmp, file_path)
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
  # （安全側にフォールバックする）。valid JSON だが Hash でない壊れ方は、デフォルト値で
  # 上書きすると復旧の余地（手動修復・AIによる復旧）を失うため abort する。
  def read_data(work_dir)
    file_path = path(work_dir)
    data = JSON.parse(File.read(file_path))
    unless data.is_a?(Hash)
      abort("#{file_path} is valid JSON but not an object; refusing to overwrite it with " \
            "defaults. Inspect/repair it manually (or with AI assistance) and re-run.")
    end

    default_data.merge(data)
  rescue JSON::ParserError
    default_data
  end
  private_class_method :read_data

  def default_data = { "confirmed_at" => nil, "pending_at" => nil, "pending_episode" => nil, "rollback_at" => nil, "last_op" => nil }
  private_class_method :default_data
end
