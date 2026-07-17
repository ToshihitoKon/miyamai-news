# frozen_string_literal: true

module Internal
  # 外部コマンド（VOICEPEAK/ffmpeg/ffprobe）失敗時のエラーメッセージ組み立てで使う。
  module CommandError
    module_function

    # stderr の末尾 max_chars 文字を切り出す。Ruby は文字列長より大きい負インデックスの
    # 範囲アクセスで nil を返す（"short"[-300..] #=> nil）ため、300文字未満の stderr
    # （一行エラーなど）では単純な err[-300..] だと失敗理由が丸ごと消えてしまう。
    def tail(err, max_chars: 300)
      err.length > max_chars ? err[-max_chars..] : err
    end
  end
end
