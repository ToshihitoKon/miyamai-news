# frozen_string_literal: true

require "tty-spinner"

module Internal
  # 時間のかかる処理の進捗表示。ci モードではアニメーションせず、開始と結果を 1 行ずつ出す。
  module Progress
    class << self
      attr_writer :ci

      def ci? = @ci == true

      # 戻り値は success(note) / error(note) を受け付けるオブジェクト。
      def start(message)
        return PlainLine.new(message) if ci?

        TTY::Spinner.new("[:spinner] #{message}", format: :dots).tap(&:auto_spin)
      end
    end

    class PlainLine
      def initialize(message)
        @message = message
        warn "[..] #{message}"
      end

      def success(note) = warn("[ok] #{@message} #{note}")
      def error(note) = warn("[ng] #{@message} #{note}")
    end
  end
end
