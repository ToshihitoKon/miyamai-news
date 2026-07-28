# frozen_string_literal: true

module Internal
  # 外部コマンド（VOICEPEAK/ffmpeg/ffprobe）失敗時のエラーメッセージ組み立てで使う。
  module CommandError
    module_function

    # stderr の末尾 max_chars 文字を切り出す。
    def tail(err, max_chars: 300)
      err.length > max_chars ? err[-max_chars..] : err
    end
  end
end
