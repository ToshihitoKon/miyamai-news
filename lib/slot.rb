# frozen_string_literal: true

# 番組の時間帯 slot を扱う。
module Slot
  module_function

  # slot の起点となる hour。
  DAY_START_HOUR = 5

  def for(time)
    case time.hour
    when DAY_START_HOUR...11 then "morning"
    when 11...17             then "afternoon"
    when 17...23             then "evening"
    else "midnight"
    end
  end

  # 実行時刻に対応する番組の日付（深夜シフト済み）。
  def broadcast_date(time)
    time.hour < DAY_START_HOUR ? (time.to_date - 1) : time.to_date
  end

  # slot の日本語表現（台本の始めの挨拶に使う）。
  JA_LABELS = {
    "morning" => "朝",
    "afternoon" => "昼",
    "evening" => "夜",
    "midnight" => "深夜"
  }.freeze

  def ja_label(slot) = JA_LABELS.fetch(slot)

  # 1 日の中での slot の時系列順（JA_LABELS のキー順＝DAY_START_HOUR 起点の時間帯順）。
  ORDER = JA_LABELS.keys.freeze

  # slot を日内の並び順（0 始まり）に変換する。
  def sort_key(slot) = ORDER.index(slot) || raise(KeyError, "unknown slot: #{slot}")

  FILENAME_PATTERN = /_(#{JA_LABELS.keys.join('|')})\.mp3\z/

  # ファイル名から slot を判定し日本語ラベルにする（表示用）。slot を持たない
  # 旧ファイル名は空文字列を返す（後方互換）。
  def ja_label_from_filename(filename)
    m = filename.match(FILENAME_PATTERN)
    m ? ja_label(m[1]) : ""
  end

  DATE_TAG_PATTERN = /(\d{8})_(#{JA_LABELS.keys.join('|')})(?:\.mp3)?\z/

  # ファイル名（mp3 でも "<date_tag>_<slot>" 形式の episode_key でもよい）から
  # [date_tag, 日内順] を取り出す。抽出できなければ nil を返す。
  def sort_key_from_filename(filename)
    m = filename.match(DATE_TAG_PATTERN)
    return nil unless m

    [m[1], sort_key(m[2])]
  end

  DATE_ONLY_PATTERN = /(\d{8})(?:\.mp3)?\z/

  # 台帳の境界計算専用: slot なし旧形式でも date_tag だけ取り出し、
  # その日の最初（sort_key 最小値）として扱う。境界計算からその行を
  # 単純に無視すると境界が繰り上がり、保持期間内の未公開ファイルまで
  # 削除対象になるため安全側に倒す。
  def conservative_sort_key_from_filename(filename)
    sort_key_from_filename(filename) || begin
      m = filename.match(DATE_ONLY_PATTERN)
      m ? [m[1], -1] : nil
    end
  end
end
