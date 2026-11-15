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

      # 並列に進む処理の進捗を 1 行ずつ並べて表示する。戻り値は start(message) を受け付け、
      # 複数スレッドから呼んでよいオブジェクト。
      def group
        return self if ci?

        SpinnerGroup.new
      end
    end

    class SpinnerGroup
      def initialize
        @multi = TTY::Spinner::Multi.new(format: :dots)
      end

      def start(message) = @multi.register("[:spinner] #{message}").tap(&:auto_spin)
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
