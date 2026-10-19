#!/usr/bin/env ruby
# frozen_string_literal: true

require "time"
require "optparse"

require_relative "lib/internal/config"
require_relative "lib/internal/node_deps"
require_relative "lib/internal/progress"
require_relative "lib/pipeline"
require_relative "lib/slot"

COMMANDS = {
  "run" => "run the pipeline up to --until (default: pipeline.until)",
  "publish" => "publish the target episode from dist/",
  "republish-ui" => "regenerate index.html / manifest.json without publishing a new episode",
  "clean" => "clean work/ and delete published dist/ artifacts (--archive: delete archived/ instead)",
}.freeze

COMMAND_OPTIONS = {
  "run" => [:until, :date, :slot],
  "publish" => [:date, :slot],
  "republish-ui" => [],
  "clean" => [:archive],
}.freeze

def parse_args(argv)
  opts = {}
  parser = OptionParser.new do |o|
    o.banner = "Usage: ruby miyamai_news.rb [#{COMMANDS.keys.join('|')}] [options]"
    o.separator ""
    o.separator "Commands (default: run):"
    COMMANDS.each { |name, desc| o.separator format("    %-14s %s", name, desc) }
    o.separator ""
    o.separator "Options:"
    o.on("--config PATH", "path to the config file (default: config.yaml)") { |v| opts[:config] = v }
    o.on("--ci", "non-interactive mode: plain progress lines instead of spinner animation") { opts[:ci] = true }
    o.on("--until STAGE", "[run] stop after STAGE (#{Config::STAGES.join('/')})") do |v|
      abort "invalid argument: --until #{v} (must be one of: #{Config::STAGES.join(', ')})" unless Config::STAGE_ORDER.key?(v)

      opts[:until] = v
    end
    o.on("--date DATE", "[run/publish] target date (e.g. 2026-07-10)") { |v| opts[:date] = Time.parse(v) }
    o.on("--slot SLOT", "[run/publish] target slot (#{Slot::JA_LABELS.keys.join('/')})") do |v|
      abort "invalid argument: --slot #{v} (must be one of: #{Slot::JA_LABELS.keys.join(', ')})" unless Slot::JA_LABELS.key?(v)

      opts[:slot] = v
    end
    o.on("--archive", "[clean] permanently delete archived artifacts under archived/") { opts[:archive] = true }
  end

  begin
    leftover = parser.parse!(argv)
    opts[:command] = leftover.shift || "run"
    abort "unknown command: #{opts[:command]}\n\n#{parser}" unless COMMANDS.key?(opts[:command])
    abort "unknown argument: #{leftover.first}" unless leftover.empty?
  rescue OptionParser::ParseError, ArgumentError => e
    abort "#{e.message}\n\n#{parser}"
  end

  unsupported = opts.keys - [:command, :config, :ci] - COMMAND_OPTIONS.fetch(opts[:command])
  abort "--#{unsupported.first} is not available for #{opts[:command]}" unless unsupported.empty?

  opts
end

ARGS = parse_args(ARGV)
Internal::Progress.ci = ARGS[:ci] || false

begin
  Config.path = File.expand_path(ARGS[:config]) if ARGS[:config]

  case ARGS[:command]
  when "republish-ui" then Config.validate_sections!("cloudflare", "assets")
  when "clean" then Config.validate_publish_target!
  else Config.validate_for!(Pipeline.target_stage_for(ARGS))
  end

  Internal::NodeDeps.validate_wrangler_build!(root_dir: __dir__) if ARGS[:command] == "republish-ui" || Pipeline.reaches?("publish", ARGS)
rescue Config::MissingConfigError, Config::MissingKeyError, Config::InvalidConfigError, ArgumentError => e
  abort e.message
rescue Internal::NodeDeps::MissingDependencyError => e
  abort e.message
end

BASE_DIR = __dir__
WORK_DIR = File.join(BASE_DIR, "work")
DIST_DIR = File.join(BASE_DIR, "dist")

def main
  Pipeline.new(args: ARGS, base_dir: BASE_DIR, work_dir: WORK_DIR, dist_dir: DIST_DIR).run
end

main if __FILE__ == $PROGRAM_NAME
