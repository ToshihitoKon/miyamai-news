# frozen_string_literal: true

require "time"
require "date"
require_relative "slot"

# 1回の番組（エピソード）のコンテキストを表す値オブジェクト。
# 「実行時刻から番組の日付・slot を導く」計算をここ 1 箇所に集約し、
# ScriptGenerator と Publisher が同じ値を共有できるようにする。
#
# now と date は 0:00-4:59 の実行でズレる（前日 midnight 扱いのため date が 1 日戻る）。
#   - now:  収集の基準時刻。何時までの記事を拾うか・いつ収集したかの時刻演算に使う。
#   - date: 番組の日付。ファイル名・表示・アーカイブの日付に使う。
class Episode
  # 収集基準時刻（Time）。時刻精度が必要な収集ロジックはこちらを使う。
  attr_reader :now
  # 番組日付（Date）。深夜シフト済み。
  attr_reader :date
  # 時間帯 slot（morning/afternoon/evening/midnight）。
  attr_reader :slot

  # 実行時刻から番組コンテキストを組み立てる。
  # date/slot を明示指定した場合はユーザー指定を尊重し、自動判定を上書きする。
  #
  # @param now [Time] 実行時刻（収集基準時刻）
  # @param date [Date, nil] 番組日付の明示指定。nil なら now から broadcast_date で決める
  # @param slot [String, nil] slot の明示指定。nil なら now の hour から決める
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

  # 始めの挨拶に埋め込む、slot の日本語表現（例: 深夜の）。
  def slot_ja = Slot.ja_label(@slot)
end
