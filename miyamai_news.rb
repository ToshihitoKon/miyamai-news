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
  gem "dry-struct"
  gem "dry-types"
end

require "time"
require "date"
require "fileutils"
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

# clean系・ui_only は pipeline.mode とは無関係だが、実際には Publisher（GCS操作）を
# 経由するため gcs セクションだけは要求する。confirm_fetch/restore_fetch は
# work/last_fetch.json のみを触り GCS も pipeline.mode も伴わないので検証を全てスキップする。
# それ以外は各コンポーネントが実行中に MissingKeyError で落ちて中途半端に失敗するのを
# 避けるため、起動直後に必要な config が揃っているか一括で検証する。Config.path= は代入した
# 時点で即座に新しいパスから読み直す設計（lib/internal/config.rb 参照）なので、--config
# 指定時の読み込みエラーもこのガードでまとめて拾えるよう同じ begin ブロック内に置く。
begin
  # cwd 基準で解決する（一般的な CLI の期待動作。__dir__ 基準だとスクリプト位置基準になり、
  # リポジトリ外のディレクトリから相対パスを指定したときに意図と異なる場所を読んでしまう）。
  Config.path = File.expand_path(ARGS[:config]) if ARGS[:config]

  if ARGS[:clean] || ARGS[:clean_archive] || ARGS[:ui_only]
    Config.validate_gcs!
  elsif !ARGS[:confirm_fetch] && !ARGS[:restore_fetch]
    Config.validate_for!(Config.mode)
  end
rescue Config::MissingConfigError, Config::MissingKeyError, Config::InvalidConfigError, ArgumentError => e
  abort e.message
end

require_relative "lib/episode"
require_relative "lib/internal/last_fetch_store"
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

# --digest-only は digest 相当、--script-only/--synthesize-only は synthesize 相当
# （facts抽出・執筆まで進む）以上、--publish-only は publish 相当以上の config が
# 検証されていないと実行できない。満たさなければ、必要な config が未検証のまま
# 実行が進んで途中で失敗するのを防ぐためここで止める。
def ensure_mode_allows!(required_mode)
  return if Config::MODE_ORDER.fetch(Config.mode) >= Config::MODE_ORDER.fetch(required_mode)

  abort "this flag requires pipeline.mode >= #{required_mode}, but pipeline.mode=#{Config.mode}"
end

def main
  args = ARGS

  if args[:clean]
    run_clean
    return
  end

  if args[:clean_archive]
    run_clean_archive
    return
  end

  if args[:ui_only]
    run_republish_ui
    return
  end

  if args[:confirm_fetch]
    run_confirm_fetch
    return
  end

  if args[:restore_fetch]
    run_restore_fetch
    return
  end

  # 番組コンテキスト（日付・slot）は実行時刻から Episode が導く。--date/--slot の明示
  # 指定があればそれを尊重する（Episode 側で自動判定を上書き）。
  episode = Episode.new(now: args[:date] || Time.now, date: args[:date]&.to_date, slot: args[:slot])

  FileUtils.mkdir_p(WORK_DIR)
  FileUtils.mkdir_p(DIST_DIR)

  if args[:publish_only]
    ensure_mode_allows!("publish")
    run_publish(episode)
    # publish_only は新規 fetch をせず既存成果物を公開するだけなので、収集 window を
    # 新しい時刻に進めてはいけない（fetch していない時刻で確定すると取りこぼす）。
    # pending が残っていれば公開＝確定として昇格させ、無ければ何もしない。
    LastFetchStore.confirm!(work_dir: WORK_DIR)
    return
  end

  # 前回 pending の確定/ロールバックは、収集の起点(since)を確定する直前＝新規 fetch が
  # 実際に走る直前にだけ尋ねればよい。既存 news スナップショットを再利用する実行（例:
  # --script-only の後にフラグなしで synthesize へ進む）は fetch しないので、確認は出ない。
  # そのタイミング制御は ScriptGenerator に任せ、対話そのものはここで on_before_fetch として渡す。
  generator = ScriptGenerator.new(
    work_dir: WORK_DIR, episode: episode,
    on_before_fetch: method(:resolve_pending_fetch!)
  )

  if args[:digest_only]
    ensure_mode_allows!("digest")
    run_digest(generator)
    LastFetchStore.mark_pending!(work_dir: WORK_DIR, at: generator.collect_since_anchor) if generator.fetched_news?
    return
  end

  if args[:script_only]
    ensure_mode_allows!("synthesize")
    run_script(generator)
    LastFetchStore.mark_pending!(work_dir: WORK_DIR, at: generator.collect_since_anchor) if generator.fetched_news?
    return
  end

  # フラグなしは pipeline.mode の上限まで、--synthesize-only は synthesize までを上限に、
  # run_digest→run_synthesize→run_publish を順に呼ぶだけ。
  if args[:synthesize_only]
    ensure_mode_allows!("synthesize")
    target_mode = "synthesize"
  else
    target_mode = Config.mode
  end

  run_digest(generator)
  run_synthesize(episode, generator) if Config::MODE_ORDER[target_mode] >= Config::MODE_ORDER["synthesize"]

  # publish まで到達するときだけ「公開＝確定」を即座に反映する。到達しないときは、
  # 新規収集が起きていれば pending 化するだけに留める（人間の確認を待つ）。
  # 収集 window の起点には、実行完了時刻(Time.now)ではなく generator が FeedCache#fetch に
  # 渡した収集基準時刻(collect_since_anchor)を使う。新規 entry の seen_at はこの時刻で
  # 記録されるので、次回はここを since に続きから拾える。
  # publish 到達でも、新規 fetch をせず既存 news を再利用しただけなら収集 window を
  # 新しい時刻へ進めてはいけない（進めると前回確定〜今回の間に登場した記事を取りこぼす）。
  # その場合は publish_only と同じく pending が残っていれば昇格するだけに留める。
  if Config::MODE_ORDER[target_mode] >= Config::MODE_ORDER["publish"]
    run_publish(episode)
    if generator.fetched_news?
      LastFetchStore.confirm_immediately!(work_dir: WORK_DIR, at: generator.collect_since_anchor)
    else
      LastFetchStore.confirm!(work_dir: WORK_DIR)
    end
  elsif generator.fetched_news?
    LastFetchStore.mark_pending!(work_dir: WORK_DIR, at: generator.collect_since_anchor)
  end
end

# 前回実行で pending_at が残っていれば、確定させるかロールバックするか尋ねる。
# --auto-confirm 指定時は対話せず自動確定する（CI等の非対話実行向け）。
# デフォルト(Enter/N)はロールバック側（安全側）: 確認を怠って収集windowが誤って
# 進むより、取りこぼしが起きない方を既定にする。
def resolve_pending_fetch!
  pending = LastFetchStore.pending_at(WORK_DIR)
  return unless pending

  if ARGS[:auto_confirm]
    LastFetchStore.confirm!(work_dir: WORK_DIR)
    warn "auto-confirmed pending fetch window: #{pending}"
    return
  end

  print "The previous fetch window is unconfirmed (#{pending}). Confirm it? Answering no rolls it back. [y/N]: "
  answer = $stdin.gets&.strip
  if answer&.match?(/\Ay\z/i)
    LastFetchStore.confirm!(work_dir: WORK_DIR)
    warn "confirmed pending fetch window: #{pending}"
  else
    LastFetchStore.rollback!(work_dir: WORK_DIR)
    warn "rolled back pending fetch window (kept confirmed_at)"
  end
end

# pending中の収集windowを確認なしで即座に確定する独立コマンド。成果物を確認できた
# タイミングで、次回実行を待たずに使う。
def run_confirm_fetch
  pending = LastFetchStore.pending_at(WORK_DIR)
  unless pending
    warn "no pending fetch window to confirm"
    return
  end

  LastFetchStore.confirm!(work_dir: WORK_DIR)
  warn "confirmed fetch window: #{pending}"
end

# 直前の人間操作（確定・pending破棄）を 1 段巻き戻す独立コマンド。間違って確定した、
# あるいは確認プロンプトを誤って連打して pending を消したときの復旧に使う。
def run_restore_fetch
  unless LastFetchStore.restorable?(WORK_DIR)
    warn "no fetch window operation to restore"
    return
  end

  LastFetchStore.restore!(work_dir: WORK_DIR)
  warn "restored fetch window to pending: #{LastFetchStore.pending_at(WORK_DIR)}"
end

# ニュース収集・AI選別・facts抽出までを実行する。pipeline.mode: digest の到達点。
# 呼び出し元が渡した ScriptGenerator を使う（生成時に on_before_fetch を仕込むため、
# 生成は main 側で行う）。実行後は同じ generator の fetched_news? で新規収集が
# 起きたかを判断する。
def run_digest(generator)
  facts_path = generator.digest

  warn "news facts: #{facts_path}"
end

# 台本だけ生成して停止する。VOICEPEAK 向けの整形はしない（人間が読む台本まで）。
# 中身を確認・手直ししたうえで、フラグなしで再実行すれば既存の台本を再利用して
# 整形〜音声合成〜publish まで続きから進む。
def run_script(generator)
  script_path = generator.generate(format: false)

  warn "script: #{script_path}"
end

# 台本執筆・tts整形・音声合成・BGM合成までを実行する。pipeline.mode: synthesize の
# 到達点。ScriptGenerator#generate は内部で digest 相当の工程を呼ぶが、run_digest が
# 作った中間ファイルがあれば再利用するだけなので、run_digest の後に呼んでも
# AI を二重に呼ばない。generator は run_digest が返したインスタンスを引き継ぎ、
# 収集が起きたかどうかの判定（fetched_news?）を最初の呼び出し時点のまま保つ。
def run_synthesize(episode, generator)
  # BGM は config の assets.bgm_path。相対パス指定なら BASE_DIR 起点で解決する。
  # index.html にクレジット表記を固定しているため（templates/index.html.erb 参照）、
  # 差し替え可能にはしていない。
  bgm_path = File.expand_path(Config.assets.bgm_path, BASE_DIR)
  output_path = episode_mp3_path(episode)
  used_news_output = episode_used_path(episode)
  transcript_output = episode_transcript_path(episode)

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
  abort "mp3 not found: #{mp3_path} (run --synthesize-only first)" unless File.exist?(mp3_path)

  used_path = episode_used_path(episode)
  used_path = nil unless used_path && File.exist?(used_path)

  transcript_path = episode_transcript_path(episode)
  transcript_path = nil unless transcript_path && File.exist?(transcript_path)

  Publisher.new(date: episode.date).run(mp3_path, used_path, transcript_path)
end

# 新しい回を公開せず、既存 archives.csv から index.html / manifest.json だけを
# 再生成する。mp3・used.txt・archives.csv・feed.xml には触れないため、Atom の
# <updated> も動かず購読者への「新着」通知は発生しない。UI 文言修正のみを
# 即時反映したいときに使う。
def run_republish_ui
  Publisher.new.republish_ui
end

# publish のたびに archived/ へ退避された(保持件数を超えた)成果物を完全削除する。
# 通常の publish/generate フローには一切影響しない、独立した掃除コマンド。
def run_clean_archive
  Publisher.new.clean_archive
end

def run_clean
  clean_work_dir
  clean_published_dist
end

# work/ の回ごとの中間ファイルを削除する。各コンポーネントが「自分が作る中間ファイルの
# glob パターン」を申告するので、それに一致するものだけを消す（ホワイトリスト方式）。
# 回をまたいで保持する状態（last_fetch.json / feed_cache.json）はパターンに含まれないので
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
      dir = File.dirname(mp3)
      episode_files = Publisher.episode_object_names(File.basename(mp3)).map { |name| File.join(dir, name) }
      FileUtils.rm_f(episode_files)
      warn "published, deleted: #{mp3}"
    else
      warn "unpublished, kept: #{mp3}"
    end
  end
end

main if __FILE__ == $PROGRAM_NAME
