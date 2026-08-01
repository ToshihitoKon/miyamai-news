#!/usr/bin/env ruby
# frozen_string_literal: true

# lib/ の各コンポーネントを束ねる薄いエントリポイント。工程のロジックは持たず、
# CLI 解析と呼び出し順の制御に徹する。CLI の使い方は README を参照。

require "bundler/inline"

# 単体で完結するよう bundler/inline で依存 gem を取得する。
gemfile do
  source "https://rubygems.org"
  gem "tty-spinner"
  gem "rss"
  gem "csv"
  gem "rexml"
  gem "dry-struct"
  gem "dry-types"
  gem "aws-sdk-s3"
end

require "time"
require "optparse"

require_relative "lib/internal/config"
require_relative "lib/slot"

def parse_args(argv)
  opts = {}
  parser = OptionParser.new do |o|
    o.banner = "Usage: ruby miyamai_news.rb [options]"
    o.on("--config PATH", "path to the config file (default: config.yaml)") { |v| opts[:config] = v }
    o.on("--clean", "clean work/ and delete published dist/ artifacts") { opts[:clean] = true }
    o.on("--clean-archive", "permanently delete archived artifacts under archived/") { opts[:clean_archive] = true }
    o.on("--ui-only", "regenerate index.html / manifest.json only") { opts[:ui_only] = true }
    o.on("--confirm-fetch", "confirm the pending fetch window (use after reviewing the artifacts)") { opts[:confirm_fetch] = true }
    o.on("--restore-fetch", "restore the fetch window discarded by the last rollback (undo an accidental rollback)") { opts[:restore_fetch] = true }
    o.on("--auto-confirm", "auto-confirm the pending fetch window without prompting (for CI)") { opts[:auto_confirm] = true }
    o.on("--digest-only", "generate news selection/summary only, then stop") { opts[:digest_only] = true }
    o.on("--script-only", "generate the script only, then stop") { opts[:script_only] = true }
    o.on("--synthesize-only", "voice/BGM synthesis only (write to dist/ and exit)") { opts[:synthesize_only] = true }
    o.on("--publish-only", "publish the target episode from dist/ only") { opts[:publish_only] = true }
    o.on("--date DATE", "target date (e.g. 2026-07-10)") { |v| opts[:date] = Time.parse(v) }
    o.on("--slot SLOT", "target slot (#{Slot::JA_LABELS.keys.join('/')})") do |v|
      abort "invalid argument: --slot #{v} (must be one of: #{Slot::JA_LABELS.keys.join(', ')})" unless Slot::JA_LABELS.key?(v)

      opts[:slot] = v
    end
  end

  begin
    leftover = parser.parse!(argv)
    abort "unknown argument: #{leftover.first}" unless leftover.empty?
  rescue OptionParser::ParseError, ArgumentError => e
    abort "#{e.message}\n\n#{parser}"
  end

  opts
end

ARGS = parse_args(ARGV)

begin
  Config.path = File.expand_path(ARGS[:config]) if ARGS[:config]

  if ARGS[:ui_only]
    Config.validate_sections!("cloudflare", "assets")
  elsif ARGS[:clean] || ARGS[:clean_archive]
    Config.validate_publish_target!
  elsif !ARGS[:confirm_fetch] && !ARGS[:restore_fetch]
    Config.validate_for!(Config.mode)
  end
rescue Config::MissingConfigError, Config::MissingKeyError, Config::InvalidConfigError, ArgumentError => e
  abort e.message
end

require_relative "lib/pipeline"

BASE_DIR = __dir__
WORK_DIR = File.join(BASE_DIR, "work")
DIST_DIR = File.join(BASE_DIR, "dist")

def main
  Pipeline.new(args: ARGS, base_dir: BASE_DIR, work_dir: WORK_DIR, dist_dir: DIST_DIR).run
end

main if __FILE__ == $PROGRAM_NAME
