# frozen_string_literal: true

# 番組の時間帯 slot を扱う。1日に複数回まわしても回ごとに別の slot を持たせ、
# ファイル名を衝突させず別エピソードとして共存させるための区分。
#
# 11:00 起点で 6 時間ずつ 4 分割する:
#   morning   5:00-10:59
#   afternoon 11:00-16:59
#   evening   17:00-22:59
#   midnight  23:00-翌 4:59
# midnight は日付をまたぐため、深夜〜早朝(0:00-4:59)の実行は前日の深夜の回として扱う
# （broadcast_date が日付を 1 日戻す）。
module Slot
  module_function

  # slot の起点となる hour。ここより前(0:00-4:59)は前日 midnight の続きとみなす。
  DAY_START_HOUR = 5

  # 実行時刻の hour から slot を決める。
  def for(time)
    case time.hour
    when DAY_START_HOUR...11 then "morning"
    when 11...17             then "afternoon"
    when 17...23             then "evening"
    else "midnight"
    end
  end

  # 実行時刻に対応する番組の日付を返す。0:00-4:59 は前日 midnight の続きなので
  # 前日扱いにする。それ以外は実行日そのまま。
  def broadcast_date(time)
    time.hour < DAY_START_HOUR ? (time.to_date - 1) : time.to_date
  end
end
