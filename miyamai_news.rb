#!/usr/bin/env ruby
# frozen_string_literal: true

# 宮舞モカのニュース番組を、台本生成から BGM 合成、公開まで一貫して作る。
#
# 各工程はコンポーネントとして lib/ 以下に分かれている:
#   ScriptGenerator  … RSS 収集 → ライター → VOICEPEAK 向け整形 で台本テキストを作る
#   VoiceSynthesizer … 台本を VOICEPEAK(宮舞モカ) で音声合成し 1 本の mp3 にする
#   AudioMixer       … ナレーションに BGM を当てて完成版 mp3 を書き出す
#   Publisher        … 完成版 mp3 を GCS に置き、再生ページ / Atom フィードを更新する
# このファイルは各コンポーネントを束ねる薄いエントリポイントに徹する。
#
# 使い方:
#   ruby miyamai_news.rb                  台本生成 → 音声合成 → BGM合成 → 公開まで一気通し
#   ruby miyamai_news.rb --generate-only  生成だけ行い dist/ に mp3(+used.txt)を書き出す
#   ruby miyamai_news.rb --publish-only   dist/ の該当回 mp3(+used.txt)を GCS へ公開する
#   ruby miyamai_news.rb --clean          work/ を掃除し、公開済みの dist/ 成果物を消す
#
#   --bgm PATH   既定 BGM(config の assets.bgm_path)を差し替える
#   --date YYYY-MM-DD / --slot morning|afternoon|evening
#                対象の回を明示する（--publish-only で過去回を公開し直すときなど）
#
# 一時ファイルは work/ 以下に置く。完成版は dist/miyamai_news_YYYYMMDD_SLOT.mp3。

require "bundler/inline"

# 単体で完結するよう bundler/inline で依存 gem を取得する。
# Ruby 4.0 で rss/csv/rexml は bundled gem になり、gemfile ブロック内では
# 明示しないと require できない。各コンポーネントの require より前に取得する。
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

require_relative "lib/config"
require_relative "lib/slot"
require_relative "lib/script_generator"
require_relative "lib/voice_synthesizer"
require_relative "lib/audio_mixer"
require_relative "lib/publisher"

# ---------------------------------------------------------------------------
# メイン: 台本生成 → 音声合成 → BGM 合成 → 公開 を順に実行
# ---------------------------------------------------------------------------

BASE_DIR = __dir__
WORK_DIR = File.join(BASE_DIR, "work")
DIST_DIR = File.join(BASE_DIR, "dist")

# dist/ に置く成果物のパス。generate と publish で同じ命名規則を共有する。
def episode_mp3_path(date_tag, slot)  = File.join(DIST_DIR, "miyamai_news_#{date_tag}_#{slot}.mp3")
def episode_used_path(date_tag, slot) = File.join(DIST_DIR, "miyamai_news_#{date_tag}_#{slot}.used.txt")

def main
  args = parse_args(ARGV)

  if args[:clean]
    run_clean
    return
  end

  date = args[:date] || Time.now
  date_tag = date.strftime("%Y%m%d")
  slot = args[:slot] || Slot.for(date)

  FileUtils.mkdir_p(WORK_DIR)
  FileUtils.mkdir_p(DIST_DIR)

  # --publish-only でなければ生成する。
  run_generate(date, date_tag, slot, args[:bgm]) unless args[:publish_only]
  # --generate-only でなければ公開する。
  run_publish(date, date_tag, slot) unless args[:generate_only]
end

# 台本生成 → 音声合成 → BGM 合成。成果物を dist/ に書き出す。
def run_generate(date, date_tag, slot, bgm_override)
  # BGM は config の assets.bgm_path。相対パス指定なら BASE_DIR 起点で解決する。
  bgm_path = bgm_override || File.expand_path(Config.get("assets.bgm_path"), BASE_DIR)
  output_path = episode_mp3_path(date_tag, slot)
  used_news_output = episode_used_path(date_tag, slot)

  generator = ScriptGenerator.new(work_dir: WORK_DIR, date: date, slot: slot)
  script_path = generator.generate
  voice_path = VoiceSynthesizer.new(work_dir: WORK_DIR, date: date, slot: slot).synthesize(script_path)
  AudioMixer.new(bgm_path: bgm_path).mix(voice_path, output_path)

  # 使用ニュース一覧を mp3 と並べて成果物として残す（work/ 側はキャッシュとして温存）。
  FileUtils.cp(generator.used_news_file, used_news_output)

  warn "完成: #{output_path}"
  warn "使用ニュース: #{used_news_output}"
end

# dist/ の該当回 mp3(+used.txt)を GCS へ公開する。
def run_publish(date, date_tag, slot)
  mp3_path = episode_mp3_path(date_tag, slot)
  abort "mp3 が見つかりません: #{mp3_path}（先に生成が必要）" unless File.exist?(mp3_path)

  used_path = episode_used_path(date_tag, slot)
  used_path = nil unless used_path && File.exist?(used_path)

  Publisher.new(date: date.to_date).run(mp3_path, used_path)
end

# 中間生成物を掃除する。work/ のキャッシュと、GCS へ公開済みの dist/ 成果物を消す。
def run_clean
  clean_work_dir
  clean_published_dist
end

# work/ の中間キャッシュを削除する。ただし last_fetch.txt（前回収集時刻の記録）は
# 残す。消すと収集 window が上限にリセットされ、次回に過去分を拾い直して重複するため。
def clean_work_dir
  targets = Dir.glob(File.join(WORK_DIR, "*")).reject { |p| File.basename(p) == "last_fetch.txt" }
  FileUtils.rm_rf(targets)
  warn "作業ディレクトリを初期化: #{WORK_DIR}"
end

# dist/ の各 mp3 のうち、GCS 上に同名が存在する（＝公開済みの）ものだけを削除する。
# 未公開の回を誤って消さないための存在確認。used.txt は対の mp3 とセットで扱う。
def clean_published_dist
  mp3s = Dir.glob(File.join(DIST_DIR, "miyamai_news_*.mp3"))
  return if mp3s.empty?

  publisher = Publisher.new
  mp3s.each do |mp3|
    if publisher.object_exists?(File.basename(mp3))
      FileUtils.rm_f([mp3, mp3.sub(/\.mp3\z/, ".used.txt")])
      warn "公開済み → 削除: #{mp3}"
    else
      warn "未公開 → 保持: #{mp3}"
    end
  end
end

# ARGV を解析する。値を取るオプション(--bgm/--date/--slot)は次の要素を消費する。
def parse_args(argv)
  opts = {}
  i = 0
  while i < argv.length
    case argv[i]
    when "--clean"         then opts[:clean] = true
    when "--generate-only" then opts[:generate_only] = true
    when "--publish-only"  then opts[:publish_only] = true
    when "--bgm"           then opts[:bgm] = argv[i += 1]
    when "--date"          then opts[:date] = Time.parse(argv[i += 1])
    when "--slot"          then opts[:slot] = argv[i += 1]
    else abort "不明な引数: #{argv[i]}"
    end
    i += 1
  end
  opts
end

main if __FILE__ == $PROGRAM_NAME
