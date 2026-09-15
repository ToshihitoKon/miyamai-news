# frozen_string_literal: true

require "English"
require_relative "episode_logger"

module Internal
  class PhaseTimer
    def initialize
      @durations = {}
    end

    def measure(name)
      start = EpisodeLogger.start_timer
      yield
    ensure
      @durations[name] = { sec: EpisodeLogger.elapsed_since(start), ok: $ERROR_INFO.nil? }
    end

    def report
      return if @durations.empty?

      warn "phase duration:"
      @durations.each do |name, d|
        status = d[:ok] ? "" : " (failed)"
        warn "  #{name}: #{d[:sec]}s#{status}"
      end
    end
  end
end
