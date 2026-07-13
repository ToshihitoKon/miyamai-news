#!/usr/bin/env ruby
# frozen_string_literal: true

# lib/ の各コンポーネントを束ねる薄いエントリポイント。工程のロジックは持たず、
# CLI 解析と呼び出し順の制御に徹する。CLI の使い方は README を参照。

require "bundler/inline"

# 単体で完結するよう bundler/inline で依存 gem を取得する。bundled gem の
# rss/csv/rexml も明示しないと後続の require で読めないため、ここに並べる。
gemfile do
  source "https://rubygems.org"
  gem "tty-spinner"
  gem "rss"
  gem "csv"
  gem "rexml"
end

require "time"
require "date"
require "fileutils"

require_relative "lib/internal/config"
require_relative "lib/episode"
require_relative "lib/script_generator"
require_relative "lib/voice_synthesizer"
require_relative "lib/audio_mixer"
require_relative "lib/publisher"

BASE_DIR = __dir__
WORK_DIR = File.join(BASE_DIR, "work")
DIST_DIR = File.join(BASE_DIR, "dist")

# dist/ に置く成果物のパス。generate と publish で同じ命名規則を共有する。
def episode_mp3_path(episode)        = File.join(DIST_DIR, "miyamai_news_#{episode.date_tag}_#{episode.slot}.mp3")
def episode_used_path(episode)       = File.join(DIST_DIR, "miyamai_news_#{episode.date_tag}_#{episode.slot}.used.txt")
# 読み仮名化前の人間可読な原稿。公開ページでは「文字起こし」として提示する。
def episode_transcript_path(episode) = File.join(DIST_DIR, "miyamai_news_#{episode.date_tag}_#{episode.slot}.transcript.txt")

def main
  args = parse_args(ARGV)

  if args[:clean]
    run_clean
    return
  end

  if args[:ui_only]
    run_republish_ui
    return
  end

  # 番組コンテキスト（日付・slot）は実行時刻から Episode が導く。--date/--slot の明示
  # 指定があればそれを尊重する（Episode 側で自動判定を上書き）。
  episode = Episode.new(now: args[:date] || Time.now, date: args[:date]&.to_date, slot: args[:slot])

  FileUtils.mkdir_p(WORK_DIR)
  FileUtils.mkdir_p(DIST_DIR)

  if args[:script_only]
    run_script(episode, cli: args[:cli])
    return
  end

  run_generate(episode, args[:bgm], cli: args[:cli]) unless args[:publish_only]
  run_publish(episode) unless args[:generate_only]
end

# 台本だけ生成して停止する。VOICEPEAK 向けの整形はしない（人間が読む台本まで）。
# 中身を確認・手直ししたうえで、フラグなしで再実行すれば既存の台本を再利用して
# 整形〜音声合成〜publish まで続きから進む。
def run_script(episode, cli: nil)
  script_path = ScriptGenerator.new(work_dir: WORK_DIR, episode: episode, cli: cli).generate(format: false)

  warn "script: #{script_path}"
end

def run_generate(episode, bgm_override, cli: nil)
  # BGM は config の assets.bgm_path。相対パス指定なら BASE_DIR 起点で解決する。
  bgm_path = bgm_override || File.expand_path(Config.get("assets.bgm_path"), BASE_DIR)
  output_path = episode_mp3_path(episode)
  used_news_output = episode_used_path(episode)
  transcript_output = episode_transcript_path(episode)

  generator = ScriptGenerator.new(work_dir: WORK_DIR, episode: episode, cli: cli)
  tts_script_path = generator.generate
  voice_path = VoiceSynthesizer.new(work_dir: WORK_DIR, episode: episode).synthesize(tts_script_path)
  AudioMixer.new(bgm_path: bgm_path).mix(voice_path, output_path)

  # 使用ニュース一覧・文字起こし(読み仮名化前の台本)を mp3 と並べて成果物として残す
  # （work/ 側はキャッシュとして温存）。
  FileUtils.cp(generator.used_news_file, used_news_output)
  FileUtils.cp(generator.script_file, transcript_output)

  warn "audio: #{output_path}"
  warn "used news: #{used_news_output}"
  warn "transcript: #{transcript_output}"
end

def run_publish(episode)
  mp3_path = episode_mp3_path(episode)
  abort "mp3 not found: #{mp3_path} (run generate first)" unless File.exist?(mp3_path)

  used_path = episode_used_path(episode)
  used_path = nil unless used_path && File.exist?(used_path)

  transcript_path = episode_transcript_path(episode)
  transcript_path = nil unless transcript_path && File.exist?(transcript_path)

  Publisher.new(date: episode.date).run(mp3_path, used_path, transcript_path)

  # publish が成功した実行時刻で収集 window の起点を確定する。以後の収集はこの時刻より
  # 後の記事だけを対象にする。Publisher#run は失敗時に内部で abort するので、ここへ
  # 到達するのは成功時のみ。起点は実行時刻(Time.now)。過去回を publish し直しても未来の
  # window を巻き戻さないよう、回の日付ではなく実行時刻を使う。
  ScriptGenerator.record_publish(work_dir: WORK_DIR, at: Time.now)
end

# 新しい回を公開せず、既存 archives.csv から index.html / manifest.json だけを
# 再生成する。mp3・used.txt・archives.csv・feed.xml には触れないため、Atom の
# <updated> も動かず購読者への「新着」通知は発生しない。UI 文言修正のみを
# 即時反映したいときに使う。
def run_republish_ui
  Publisher.new.republish_ui
end

def run_clean
  clean_work_dir
  clean_published_dist
end

# work/ の回ごとの中間ファイルを削除する。各コンポーネントが「自分が作る中間ファイルの
# glob パターン」を申告するので、それに一致するものだけを消す（ホワイトリスト方式）。
# 回をまたいで保持する状態（last_fetch.txt / feed_cache.json）はパターンに含まれないので
# 残る。消すと過去に見た記事を新着として拾い直し、重複紹介が起きるため。
def clean_work_dir
  patterns = ScriptGenerator.work_globs(WORK_DIR) + VoiceSynthesizer.work_globs(WORK_DIR)
  FileUtils.rm_rf(patterns.flat_map { |pat| Dir.glob(pat) })
  warn "reset work dir: #{WORK_DIR}"
end

# dist/ の各 mp3 のうち、GCS 上に同名が存在する（＝公開済みの）ものだけを削除する。
# 未公開の回を誤って消さないための存在確認。used.txt/transcript.txt は対の mp3 とセットで扱う。
def clean_published_dist
  mp3s = Dir.glob(File.join(DIST_DIR, "miyamai_news_*.mp3"))
  return if mp3s.empty?

  publisher = Publisher.new
  mp3s.each do |mp3|
    if publisher.object_exists?(File.basename(mp3))
      FileUtils.rm_f([mp3, mp3.sub(/\.mp3\z/, ".used.txt"), mp3.sub(/\.mp3\z/, ".transcript.txt")])
      warn "published, deleted: #{mp3}"
    else
      warn "unpublished, kept: #{mp3}"
    end
  end
end

# ARGV を解析する。値を取るオプション(--bgm/--date/--slot)は次の要素を消費する。
def parse_args(argv)
  opts = {}
  i = 0
  while i < argv.length
    case argv[i]
    when "--clean"                then opts[:clean] = true
    when "--ui-only"              then opts[:ui_only] = true
    when "--script-only"          then opts[:script_only] = true
    when "--generate-only"        then opts[:generate_only] = true
    when "--publish-only"         then opts[:publish_only] = true
    when "--cli"                  then opts[:cli] = argv[i += 1]
    when "--antigravity", "--agy" then opts[:cli] = "antigravity"
    when "--claude"               then opts[:cli] = "claude"
    when "--bgm"                  then opts[:bgm] = argv[i += 1]
    when "--date"                 then opts[:date] = Time.parse(argv[i += 1])
    when "--slot"                 then opts[:slot] = argv[i += 1]
    else abort "unknown argument: #{argv[i]}"
    end
    i += 1
  end
  opts
end

main if __FILE__ == $PROGRAM_NAME
