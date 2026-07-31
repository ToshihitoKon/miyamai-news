# frozen_string_literal: true

module Internal
  # AI 出力の前置き（「整形しました」等）を取り除く共通処理。
  # 本体の開始位置をブロックに判定させ、それより前を切り落とす。
  module PreambleStripper
    module_function

    # 開始位置（文字列 index）が見つからなければ text をそのまま返す。
    def strip_before(text)
      idx = yield(text)
      return text unless idx

      "#{text[idx..].strip}\n"
    end
  end
end
