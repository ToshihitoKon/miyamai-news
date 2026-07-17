# frozen_string_literal: true

require "time"
require "json"

# 収集 window の起点を work/last_fetch.json に永続化する。ScriptGenerator の
# 収集ロジックとは無関係な、状態遷移と読み書きだけに責務を絞ったモジュール。
#
# 状態はすべて work/last_fetch.json 側にあり、保持すべきインスタンス状態は無い
# （work_dir だけが引数）。そのため状態を持つオブジェクトにはせず、work_dir を受け取る
# モジュール関数の集まりにしている。
#
# 収集 window は「実行が完了したら即確定」ではなく、人間が成果物（facts/台本/mp3）を
# 確認して次に進んでよいと判断した時点で確定する（publish だけは公開自体が確定行為
# なので例外、.confirm_immediately! を使う）。そのため状態を持つ。
#   confirmed_at: 確定済みの収集window起点。ScriptGenerator が収集の since に使う値。
#   pending_at:   直近の実行で新規収集が起きたが、まだ確認していない時刻。
#   rollback_at:  直近の confirm!/rollback! で失われた値を退避する 1 段の Undo バッファ。
#   last_op:      その rollback_at が「どの操作の Undo 用か」。"confirm" か "discard"。
#
# .restore! は人間の意思決定（.confirm!=確定 / .rollback!=pending破棄）を 1 段だけ巻き戻す。
# confirm と discard は復元後の状態が違う（confirm の取り消しは confirmed_at も戻すが、
# discard の取り消しは pending_at だけ戻す）ため、どちらを巻き戻すかを last_op で見分ける。
# 自動的な .mark_pending!/.confirm_immediately! は人間の操作ではないので Undo 対象にせず、
# last_op をクリアする。
module LastFetchStore
  module_function

  def path(work_dir) = File.join(work_dir, "last_fetch.json")

  # 旧形式(単一 ISO8601 時刻、mode 非依存)の記録ファイル。存在すれば読み込み時に
  # 自動移行する。
  def legacy_path(work_dir) = File.join(work_dir, "last_fetch.txt")

  # confirmed_at/pending_at/rollback_at/last_op の4キーを保証して返す（無ければ nil）。
  def load(work_dir)
    return migrate!(work_dir) if File.exist?(path(work_dir))

    migrate_legacy(work_dir) || default_data
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

  # pending_at を捨てる。confirmed_at は現状維持のまま変えない。.restore! で巻き戻せるよう、
  # 捨てる pending_at を rollback_at へ退避し last_op を discard にする。確認プロンプトを
  # 誤って連打して pending を消しても後から復旧できる。pending_at が無ければ何もしない。
  def rollback!(work_dir:)
    data = load(work_dir)
    return unless data["pending_at"]

    write(work_dir, data.merge("pending_at" => nil, "rollback_at" => data["pending_at"], "last_op" => "discard"))
  end

  # 直前の人間操作（confirm! / rollback!）を 1 段だけ巻き戻す。復元後の状態は操作ごとに
  # 違うので last_op で見分ける。
  #   confirm の取り消し: 昇格した confirmed_at を pending_at へ戻し、退避してあった元の
  #                       confirmed_at（rollback_at）を confirmed_at へ戻す。
  #   discard の取り消し: 捨てた pending_at（rollback_at）を pending_at へ戻す。
  # 巻き戻したら Undo バッファはクリアする（1 段のみ、Redo はしない）。巻き戻せる状態が
  # 無ければ何もしない（冪等）。
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
  # （公開自体が確定行為なので対話を挟まない）。人間の操作ではない（Undo 対象にしない）ので
  # Undo バッファはクリアする。
  def confirm_immediately!(work_dir:, at:)
    write(work_dir, load(work_dir).merge("confirmed_at" => at.iso8601, "pending_at" => nil, "rollback_at" => nil, "last_op" => nil))
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

  # last_fetch.json（存在する前提で呼ぶ）を新形式(confirmed_at/pending_at/rollback_at/
  # last_op)で返す。旧 mode 別キー形式が残っていれば自動移行してから返す。パース不能な
  # 壊れたファイルは移行せず残し、空扱いで返す（安全側にフォールバックする）。
  def migrate!(work_dir)
    data = JSON.parse(File.read(path(work_dir)))
    # last_op 導入前の新形式にも欠けているキーを default で補って返す。
    return default_data.merge(data) if new_format?(data)

    migrated = default_data.merge("confirmed_at" => most_advanced(data))
    write(work_dir, migrated)
    migrated
  rescue JSON::ParserError
    default_data
  end
  private_class_method :migrate!

  def default_data = { "confirmed_at" => nil, "pending_at" => nil, "rollback_at" => nil, "last_op" => nil }
  private_class_method :default_data

  def new_format?(data) = %w[confirmed_at pending_at rollback_at last_op].any? { |k| data.key?(k) }
  private_class_method :new_format?

  # 旧 mode 別キー形式（digest/synthesize/publish）から、最も進んだ値を採る。
  # 収集window の起点は遅い方が安全（記事の取りこぼしを避けられる）。
  def most_advanced(data)
    %w[publish synthesize digest].each { |mode| return data[mode] if data[mode] }
    nil
  end
  private_class_method :most_advanced

  def migrate_legacy(work_dir)
    return nil unless File.exist?(legacy_path(work_dir))

    at = Time.iso8601(File.read(legacy_path(work_dir)).strip)
    data = default_data.merge("confirmed_at" => at.iso8601)
    write(work_dir, data)
    File.delete(legacy_path(work_dir))
    data
  rescue ArgumentError
    nil # 壊れた旧ファイルは移行せず残す（呼び出し側で安全側にフォールバックする）
  end
  private_class_method :migrate_legacy
end
