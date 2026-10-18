# frozen_string_literal: true

module Internal
  # monotonic clock 上の締め切り時刻。複数のスレッドから読み取り専用で共有してよい。
  class Deadline
    def self.in(sec) = new(now + sec)
    def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def initialize(at)
      @at = at
    end

    def remaining_sec = @at - self.class.now
  end
end
