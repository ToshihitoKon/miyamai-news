# frozen_string_literal: true

require "time"
require "date"
require_relative "slot"

# 1回の番組（エピソード）のコンテキストを表す値オブジェクト。「実行時刻から番組の
# 日付・slot を導く」計算を1箇所に集約し、ScriptGenerator と Publisher が同じ値を
# 共有できるようにする。
#
#   now:  収集基準時刻（Time）。時刻精度が必要な収集ロジックに使う。
#   date: 番組日付（Date）。深夜シフト済み。ファイル名・表示・アーカイブに使う。
#   slot: 時間帯 slot（morning/afternoon/evening/midnight）。
#
# now と date は 0:00-4:59 の実行でズレる（Slot.broadcast_date が前日 midnight 扱いに
# して date を1日戻すため）。また --date で date を明示上書きする場合も、now は
# 呼び出し側が常に実時刻を渡す契約になっている（詳細は CLAUDE.md 参照）。
class Episode
  attr_reader :now, :date, :slot

  # date/slot を明示指定した場合は自動判定より優先する。
  def initialize(now: Time.now, date: nil, slot: nil)
    @now = now
    @date = date || Slot.broadcast_date(now)
    @slot = slot || Slot.for(now)
  end

  # ファイル名・GCS オブジェクト名に使う日付タグ（例: 20260712）。
  def date_tag = @date.strftime("%Y%m%d")

  # 台本プロンプトに埋め込む表示用の日付（例: 2026年07月12日）。
  def today_ja = @date.strftime("%Y年%m月%d日")

  # 始めの挨拶に埋め込む、年を省いた表示用の日付（例: 7月12日）。
  def greeting_date_ja = @date.strftime("%-m月%-d日")

  # 始めの挨拶に埋め込む、slot の日本語表現（例: 深夜）。「の」は writer.prompt.erb 側で付与する。
  def slot_ja = Slot.ja_label(@slot)
end
