# frozen_string_literal: true

require "fileutils"
require_relative "episode"
require_relative "internal/config"
require_relative "internal/last_fetch_store"
require_relative "internal/episode_logger"
require_relative "script_generator"
require_relative "voice_synthesizer"
require_relative "audio_mixer"
require_relative "publisher"

# miyamai_news.rb の CLI フラグに応じた工程の呼び分けと、その間の副作用
# （work/dist の mkdir・EpisodeLogger の configure・LastFetchStore の確定/pending化）
# を一元管理するオーケストレーター。新しいドメインロジックは持たず、既存の
# ScriptGenerator/Publisher/LastFetchStore/Internal::EpisodeLogger の呼び出し順序を
# 集約するだけに徹する（詳細は CLAUDE.md「Pipeline」参照）。
class Pipeline
  def initialize(args:, base_dir:, work_dir:, dist_dir:)
    @args = args
    @base_dir = base_dir
    @work_dir = work_dir
    @dist_dir = dist_dir
  end

  def run
    return run_clean_command if @args[:clean]
    return run_clean_archive_command if @args[:clean_archive]
    return run_republish_ui_command if @args[:ui_only]
    return run_confirm_fetch_command if @args[:confirm_fetch]
    return run_restore_fetch_command if @args[:restore_fetch]

    setup_episode!

    if @args[:publish_only]
      # publish_only は新規収集を一切行わないので、フィードキャッシュを持つ
      # ScriptGenerator（FeedCache.new が旧台帳ファイルを読む）を生成しない
      # （元の main も generator 構築より前に return していた挙動を維持する）。
      run_publish_only
    else
      setup_generator!

      if @args[:digest_only]
        run_digest_only
      elsif @args[:script_only]
        run_script_only
      else
        run_full
      end
    end
  end

  private

  # --- Episode非依存の独立コマンド --------------------------------------
  # --clean/--clean-archive/--ui-only/--confirm-fetch/--restore-fetch は Episode を
  # 作らない（EpisodeLogger.configure されないまま no-op で動く）既存の不変条件を
  # 維持するため、setup_episode! より前で処理する。

  def run_confirm_fetch_command
    pending = LastFetchStore.pending_at(@work_dir)
    unless pending
      warn "no pending fetch window to confirm"
      return
    end

    ScriptGenerator.record_used_news_history!(work_dir: @work_dir, episode_key: LastFetchStore.confirm!(work_dir: @work_dir))
    warn "confirmed fetch window: #{pending}"
  end

  def run_restore_fetch_command
    unless LastFetchStore.restorable?(@work_dir)
      warn "no fetch window operation to restore"
      return
    end

    LastFetchStore.restore!(work_dir: @work_dir)
    warn "restored fetch window to pending: #{LastFetchStore.pending_at(@work_dir)}"
  end

  def run_republish_ui_command
    Publisher.new.republish_ui
  end

  def run_clean_archive_command
    Publisher.new.clean_archive
  end

  def run_clean_command
    clean_work_dir
    clean_published_dist
  end

  def clean_work_dir
    patterns = ScriptGenerator.work_globs(@work_dir) + VoiceSynthesizer.work_globs(@work_dir) +
      Internal::EpisodeLogger.work_globs(@work_dir)
    FileUtils.rm_rf(patterns.flat_map { |pat| Dir.glob(pat) })
    warn "reset work dir: #{@work_dir}"
  end

  def clean_published_dist
    mp3s = Dir.glob(File.join(@dist_dir, "miyamai_news_*.mp3"))
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

  # --- Episode依存の経路 --------------------------------------------------

  # 番組コンテキスト（日付・slot）は実行時刻から Episode が導く。--date/--slot の
  # 明示指定があればそれを尊重する（Episode 側で自動判定を上書き）。
  def setup_episode!
    @episode = Episode.new(now: @args[:date] || Time.now, date: @args[:date]&.to_date, slot: @args[:slot])

    FileUtils.mkdir_p(@work_dir)
    FileUtils.mkdir_p(@dist_dir)
    Internal::EpisodeLogger.configure(File.join(@work_dir, "#{@episode.date_tag}_#{@episode.slot}.log"))
  end

  # 前回 pending の確定/ロールバックは、収集の起点(since)を確定する直前＝新規 fetch が
  # 実際に走る直前に ScriptGenerator が自分で尋ねる。既存 news スナップショットを再利用する
  # 実行（例: --script-only の後にフラグなしで synthesize へ進む）は fetch しないので、確認は
  # 出ない。auto_confirm は CI 等の非対話実行で確認を飛ばして自動確定するかどうか。
  def setup_generator!
    @generator = ScriptGenerator.new(work_dir: @work_dir, episode: @episode, auto_confirm: @args[:auto_confirm] || false)
  end

  def run_publish_only
    ensure_mode_allows!("publish")
    run_publish
    # publish_only は新規 fetch をせず既存成果物を公開するだけなので、収集 window を
    # 新しい時刻に進めてはいけない（fetch していない時刻で確定すると取りこぼす）。
    # pending が残っていれば公開＝確定として昇格させ、無ければ何もしない。
    ScriptGenerator.record_used_news_history!(work_dir: @work_dir, episode_key: LastFetchStore.confirm!(work_dir: @work_dir))
  end

  def run_digest_only
    ensure_mode_allows!("digest")
    run_digest
    mark_pending_if_fetched!
  end

  def run_script_only
    ensure_mode_allows!("synthesize")
    run_script
    mark_pending_if_fetched!
  end

  # フラグなしは pipeline.mode の上限まで、--synthesize-only は synthesize までを上限に、
  # run_digest→run_synthesize→run_publish を順に呼ぶだけ。
  def run_full
    if @args[:synthesize_only]
      ensure_mode_allows!("synthesize")
      target_mode = "synthesize"
    else
      target_mode = Config.mode
    end

    run_digest
    run_synthesize if Config::MODE_ORDER[target_mode] >= Config::MODE_ORDER["synthesize"]

    # publish 到達時のみ「公開＝確定」を即座に反映し、それ以外は pending 化に留める
    # （収集 window の確定タイミングの詳細は CLAUDE.md「LastFetchStore / 収集 window」参照）。
    if Config::MODE_ORDER[target_mode] >= Config::MODE_ORDER["publish"]
      run_publish
      if @generator.fetched_news?
        LastFetchStore.confirm_immediately!(work_dir: @work_dir, at: @generator.collect_since_anchor)
        # 公開＝確定した今回の回を紹介済みニュース履歴へ追記する（confirm_immediately! は
        # pending を経由しないので episode_key を返さない。今回の episode から直接渡す）。
        ScriptGenerator.record_used_news_history!(work_dir: @work_dir, episode_key: @generator.episode_key)
      else
        # 既存 news の再利用でも、pending が残っていれば昇格した回を履歴へ追記する。
        ScriptGenerator.record_used_news_history!(work_dir: @work_dir, episode_key: LastFetchStore.confirm!(work_dir: @work_dir))
      end
    else
      mark_pending_if_fetched!
    end
  end

  # --digest-only は digest 相当、--script-only/--synthesize-only は synthesize 相当
  # （facts抽出・執筆まで進む）以上、--publish-only は publish 相当以上の config が
  # 検証されていないと実行できない。満たさなければ、必要な config が未検証のまま
  # 実行が進んで途中で失敗するのを防ぐためここで止める。
  def ensure_mode_allows!(required_mode)
    return if Config::MODE_ORDER.fetch(Config.mode) >= Config::MODE_ORDER.fetch(required_mode)

    abort "this flag requires pipeline.mode >= #{required_mode}, but pipeline.mode=#{Config.mode}"
  end

  # 新規収集が起きていれば収集windowを pending 化する（詳細は CLAUDE.md「LastFetchStore /
  # 収集 window」参照）。
  def mark_pending_if_fetched!
    return unless @generator.fetched_news?

    LastFetchStore.mark_pending!(work_dir: @work_dir, at: @generator.collect_since_anchor, episode_key: @generator.episode_key)
  end

  # ニュース収集・AI選別・facts抽出までを実行する。pipeline.mode: digest の到達点。
  def run_digest
    facts_path = @generator.digest

    warn "news facts: #{facts_path}"
  end

  # 台本だけ生成して停止する。VOICEPEAK 向けの整形はしない（人間が読む台本まで）。
  # 中身を確認・手直ししたうえで、フラグなしで再実行すれば既存の台本を再利用して
  # 整形〜音声合成〜publish まで続きから進む。
  def run_script
    script_path = @generator.generate(format: false)

    warn "script: #{script_path}"
  end

  # 台本執筆・tts整形・音声合成・BGM合成までを実行する。pipeline.mode: synthesize の
  # 到達点。ScriptGenerator#generate は内部で digest 相当の工程を呼ぶが、run_digest が
  # 作った中間ファイルがあれば再利用するだけなので、run_digest の後に呼んでも
  # AI を二重に呼ばない。
  def run_synthesize
    # BGM は config の assets.bgm_path。相対パス指定なら base_dir 起点で解決する。
    # index.html にクレジット表記を固定しているため（templates/index.html.erb 参照）、
    # 差し替え可能にはしていない。
    bgm_path = File.expand_path(Config.assets.bgm_path, @base_dir)
    output_path = episode_mp3_path
    used_news_output = episode_used_path
    transcript_output = episode_transcript_path

    tts_script_path = @generator.generate
    voice_path = VoiceSynthesizer.new(work_dir: @work_dir, episode: @episode).synthesize(tts_script_path)
    AudioMixer.new(bgm_path: bgm_path).mix(voice_path, output_path)

    # 使用ニュース一覧・文字起こし(読み仮名化前の台本)を mp3 と並べて成果物として残す
    # （work/ 側はキャッシュとして温存）。
    FileUtils.cp(@generator.used_news_file, used_news_output)
    FileUtils.cp(@generator.script_file, transcript_output)

    warn "audio: #{output_path}"
    warn "used news: #{used_news_output}"
    warn "transcript: #{transcript_output}"
  end

  def run_publish
    mp3_path = episode_mp3_path
    abort "mp3 not found: #{mp3_path} (run --synthesize-only first)" unless File.exist?(mp3_path)

    used_path = episode_used_path
    used_path = nil unless used_path && File.exist?(used_path)

    transcript_path = episode_transcript_path
    transcript_path = nil unless transcript_path && File.exist?(transcript_path)

    Publisher.new(date: @episode.date).run(mp3_path, used_path, transcript_path)
  end

  # dist/ に置く成果物のパス。generate と publish で同じ命名規則を共有する。
  def episode_mp3_path = File.join(@dist_dir, "miyamai_news_#{@episode.date_tag}_#{@episode.slot}.mp3")
  def episode_used_path = File.join(@dist_dir, "miyamai_news_#{@episode.date_tag}_#{@episode.slot}.used.txt")
  # 読み仮名化前の人間可読な原稿。公開ページでは「文字起こし」として提示する。
  def episode_transcript_path = File.join(@dist_dir, "miyamai_news_#{@episode.date_tag}_#{@episode.slot}.transcript.txt")
end
