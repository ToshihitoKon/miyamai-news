# frozen_string_literal: true

# 番組の時間帯 slot を扱う。1日に朝・昼・夜と複数回まわしてもファイル名が
# 衝突せず、それぞれ別エピソードとして共存できるようにするための区分。
module Slot
  module_function

  # 実行時刻から時間帯 slot を決める。
  #   morning   = 0:00〜11:59
  #   afternoon = 12:00〜17:59
  #   evening   = 18:00〜23:59
  def for(time)
    case time.hour
    when 0...12  then "morning"
    when 12...18 then "afternoon"
    else "evening"
    end
  end
end
