#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/internal/config"
require_relative "../lib/internal/relative_path"
require_relative "lib/tts_reading_check"

options = {}

parser = OptionParser.new do |o|
  o.banner = "Usage: bundle exec ruby scripts/check_tts_reading.rb [TTS_SCRIPT_PATH] [options]"
  o.separator ""
  o.separator "Synthesize a tts_script chunk by chunk with VOICEPEAK, transcribe the audio with agy and"
  o.separator "write suspected misreadings to tts_report.md. Saved wavs and transcription are reused."
  o.separator "TTS_SCRIPT_PATH defaults to the latest work/handoff_tts_script_*.txt."
  o.separator ""
  o.separator "Options:"
  o.on("--retranscribe", "transcribe again even if a saved transcription matches") do
    options[:retranscribe] = true
  end
  o.on("--resynthesize", "synthesize every wav again (e.g. after changing the VOICEPEAK dictionary);",
    "the saved transcription is reused only if the audio is byte-identical") do
    options[:resynthesize] = true
  end
end

begin
  args = parser.parse(ARGV)
rescue OptionParser::ParseError => e
  abort "#{e.message}\n\n#{parser}"
end
abort "too many arguments\n\n#{parser}" if args.size > 1

work_dir = File.join(Config::ROOT_DIR, "work")
given_path = args.first
tts_script_path = given_path ? File.expand_path(given_path) : TtsReadingCheck.latest_tts_script(work_dir)
abort "no handoff_tts_script_*.txt in #{Internal::RelativePath.from_root(work_dir)}/" unless tts_script_path
abort "tts_script not found: #{tts_script_path}" unless File.file?(tts_script_path)

begin
  report_path = TtsReadingCheck.new(
    tts_script_path: tts_script_path,
    work_dir: work_dir,
    report_path: File.join(Config::ROOT_DIR, "tts_report.md"),
    **options
  ).run
rescue Config::MissingConfigError, Config::MissingKeyError, Config::InvalidConfigError => e
  abort e.message
end

puts "report: #{Internal::RelativePath.from_root(report_path)}"
