# frozen_string_literal: true

# 番組の時間帯 slot を扱う。1日に複数回まわしても回ごとに別の slot を持たせ、
# ファイル名を衝突させず別エピソードとして共存させるための区分。
module Slot
  module_function

  # 実行時刻の hour から slot を決める。
  def for(time)
    case time.hour
    when 0...12  then "morning"
    when 12...18 then "afternoon"
    else "evening"
    end
  end
end
