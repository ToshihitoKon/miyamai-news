# frozen_string_literal: true

require "fileutils"
require_relative "episode"
require_relative "internal/config"
require_relative "internal/last_fetch_store"
require_relative "internal/used_news_history"
require_relative "internal/episode_logger"
require_relative "internal/phase_timer"
require_relative "internal/relative_path"
require_relative "internal/r2_storage"
require_relative "internal/remote_state"
require_relative "internal/handoff"
require_relative "internal/used_news_formatter"
require_relative "script_generator"
require_relative "voice_synthesizer"
require_relative "audio_mixer"
require_relative "publisher"

# miyamai_news.rb の CLI フラグに応じた工程の呼び分けを担うオーケストレーター。
class Pipeline
  HANDOFF_WORK_GLOB = "handoff_*.txt"

  def initialize(args:, base_dir:, work_dir:, dist_dir:, phase_timer: Internal::PhaseTimer.new)
    @args = args
    @base_dir = base_dir
    @work_dir = work_dir
    @dist_dir = dist_dir
    @phase_timer = phase_timer
  end

  def self.target_mode_for(args)
    return nil if args[:clean] || args[:clean_archive] || args[:ui_only]
    return "digest" if args[:digest_only]
    return "synthesize" if args[:script_only] || args[:synthesize_only] || args[:handoff_only]

    Config.mode
  end

  # args と現在の Config.mode の組み合わせで、この起動が mode まで到達するか。
  def self.reaches?(mode, args)
    target = target_mode_for(args)
    !target.nil? && Config::MODE_ORDER[target] >= Config::MODE_ORDER[mode]
  end

  def run
    return run_clean_command if @args[:clean]
    return run_clean_archive_command if @args[:clean_archive]
    return run_republish_ui_command if @args[:ui_only]

    setup_episode!

    if @args[:publish_only]
      run_publish_only
    elsif @args[:digest_only]
      run_digest_only
    elsif @args[:script_only]
      run_script_only
    else
      run_full
    end
  ensure
    @phase_timer.report
  end

  private

  def relative(path) = Internal::RelativePath.from_root(path)

  # --- Episode非依存の独立コマンド --------------------------------------

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
               Internal::EpisodeLogger.work_globs(@work_dir) +
               [File.join(@work_dir, HANDOFF_WORK_GLOB), File.join(@work_dir, Internal::RemoteState::BASE_REVISION_FILE)]
    FileUtils.rm_rf(patterns.flat_map { |pat| Dir.glob(pat) })
    warn "reset work dir: #{relative(@work_dir)}"
  end

  def clean_published_dist
    mp3s = Dir.glob(File.join(@dist_dir, "miyamai_news_*.mp3"))
    return if mp3s.empty?

    filenames = mp3s.map { |mp3| File.basename(mp3) }
    prunable = Publisher.new.prunable_from_dist(filenames)

    mp3s.each do |mp3|
      filename = File.basename(mp3)
      if prunable.include?(filename)
        dir = File.dirname(mp3)
        episode_files = Publisher.episode_object_names(filename).map { |name| File.join(dir, name) }
        FileUtils.rm_f(episode_files)
        warn "pruned: #{relative(mp3)}"
      else
        warn "kept: #{relative(mp3)}"
      end
    end
  end

  # --- Episode依存の経路 --------------------------------------------------

  JST_UTC_OFFSET_SEC = 9 * 3600

  def setup_episode!
    now = Time.now
    if (@args[:date].nil? || @args[:slot].nil?) && now.utc_offset != JST_UTC_OFFSET_SEC
      abort "the current episode (date/slot) is determined in JST, but the local timezone is UTC#{now.strftime('%:z')}. " \
            "Run with TZ=Asia/Tokyo or pass both --date and --slot."
    end
    @episode = Episode.new(now: now, date: @args[:date]&.to_date, slot: @args[:slot])

    FileUtils.mkdir_p(@work_dir)
    FileUtils.mkdir_p(@dist_dir)
    Internal::EpisodeLogger.configure(File.join(@work_dir, "#{@episode.date_tag}_#{@episode.slot}.log"))
  end

  # 内部状態の作業コピーを用意してから ScriptGenerator を作る。
  def setup_generator!
    checkout_state!
    @generator = ScriptGenerator.new(work_dir: @work_dir, episode: @episode)
  end

  # 戻り値は :pulled（R2 から取得）か :resumed（未完了の実行の作業コピーを引き継ぎ）。
  def checkout_state!
    previous_owner = remote_state.checked_out_by
    result = remote_state.checkout!(owner: episode_key)
    if result == :pulled
      warn "pulled pipeline state from R2"
    elsif previous_owner == episode_key
      warn "resumed unfinished local pipeline state"
    else
      warn "resumed unfinished local pipeline state left by #{previous_owner} (run --clean to discard it instead)"
    end
    result
  rescue Internal::RemoteState::Missing, Internal::RemoteState::Conflict => e
    abort e.message
  end

  def push_state!
    remote_state.push!
    warn "pushed pipeline state to R2"
  rescue Internal::RemoteState::Conflict => e
    abort e.message
  end

  def run_publish_only
    ensure_mode_allows!("publish")
    run_publish
    mark_handoff_done
  end

  def run_digest_only
    ensure_mode_allows!("digest")
    setup_generator!
    run_digest
  end

  def run_script_only
    ensure_mode_allows!("synthesize")
    setup_generator!
    run_script
  end

  def run_full
    target_mode = full_run_target_mode

    unless Config::MODE_ORDER[target_mode] >= Config::MODE_ORDER["synthesize"]
      setup_generator!
      return run_digest
    end

    prepare_handoff
    return if @args[:handoff_only]

    run_synthesize
    return unless Config::MODE_ORDER[target_mode] >= Config::MODE_ORDER["publish"]

    run_publish
    mark_handoff_done
  end

  def full_run_target_mode
    return "synthesize" if @args[:handoff_only]
    return Config.mode unless @args[:synthesize_only]

    ensure_mode_allows!("synthesize")
    "synthesize"
  end

  # この回の台本一式を R2 に用意する。既に置かれていればそれを使い、生成しない。
  def prepare_handoff
    if handoff.exist?(episode_key)
      warn "reuse handoff: #{episode_key}"
      return
    end
    abort "already published: #{mp3_filename} (use --date/--slot to target another episode)" if publisher.published?(mp3_filename)

    setup_generator!
    run_digest
    tts_script_path = @phase_timer.measure("writer") { @generator.generate }
    used_news = UsedNewsFormatter.ensure_valid!(File.read(@generator.used_news_file))
    File.write(@generator.used_news_file, used_news)

    ensure_no_concurrent_run!
    commit_episode!
    push_state!
    handoff.upload!(episode_key,
      tts_script: File.read(tts_script_path), script: File.read(@generator.script_file), used_news: used_news)
    warn "handoff: #{episode_key}"
  end

  def ensure_no_concurrent_run!
    abort "handoff #{episode_key} was uploaded by another run meanwhile; discard this run with --clean" if handoff.exist?(episode_key)

    remote_state.ensure_current!
  rescue Internal::RemoteState::Conflict => e
    abort e.message
  end

  # この回の収集 window を確定して履歴に記録する。
  def commit_episode!
    at = @generator.collected_at or abort "collection time not found for #{episode_key}"
    LastFetchStore.commit!(work_dir: @work_dir, episode_key: episode_key, at: at)
    ScriptGenerator.record_used_news_history!(work_dir: @work_dir, episode_key: episode_key)
  rescue LastFetchStore::OlderEpisodeError => e
    abort e.message
  end

  def mark_handoff_done
    moved = handoff.mark_done!(episode_key)
    warn "handoff done: #{episode_key}" if moved.positive?
  end

  def ensure_mode_allows!(required_mode)
    return if Config::MODE_ORDER.fetch(Config.mode) >= Config::MODE_ORDER.fetch(required_mode)

    abort "this flag requires pipeline.mode >= #{required_mode}, but pipeline.mode=#{Config.mode}"
  end

  # ニュース収集・AI選別・facts抽出までを実行する。pipeline.mode: digest の到達点。
  def run_digest
    facts_path = @phase_timer.measure("digest") { @generator.digest }

    warn "news facts: #{relative(facts_path)}"
  end

  def run_script
    facts_path = @phase_timer.measure("digest") { @generator.digest }
    warn "news facts: #{relative(facts_path)}"

    script_path = @phase_timer.measure("writer") { @generator.generate(format: false) }
    warn "script: #{relative(script_path)}"
  end

  # R2 の台本一式から音声合成・BGM合成までを実行する。pipeline.mode: synthesize の到達点。
  def run_synthesize
    bgm_path = File.expand_path(Config.assets.bgm_path, @base_dir)
    output_path = episode_mp3_path

    downloaded = Internal::Handoff::FILES.keys.to_h { |name| [name, handoff_work_path(name)] }

    @phase_timer.measure("voice") do
      handoff.download!(episode_key, downloaded)
      voice_path = VoiceSynthesizer.new(work_dir: @work_dir, episode: @episode).synthesize(downloaded[:tts_script])
      AudioMixer.new(bgm_path: bgm_path).mix(voice_path, output_path)
    end

    FileUtils.cp(downloaded[:used_news], episode_used_path)
    FileUtils.cp(downloaded[:script], episode_transcript_path)

    warn "audio: #{relative(output_path)}"
    warn "used news: #{relative(episode_used_path)}"
    warn "transcript: #{relative(episode_transcript_path)}"
  end

  def run_publish
    @phase_timer.measure("publish") do
      mp3_path = episode_mp3_path
      abort "mp3 not found: #{relative(mp3_path)} (run --synthesize-only first)" unless File.exist?(mp3_path)

      used_path = episode_used_path
      used_path = nil unless used_path && File.exist?(used_path)

      transcript_path = episode_transcript_path
      transcript_path = nil unless transcript_path && File.exist?(transcript_path)

      publisher.run(mp3_path, used_path, transcript_path)
    end
  end

  def storage = @storage ||= Internal::R2Storage.from_config
  def handoff = @handoff ||= Internal::Handoff.new(storage:)
  def remote_state = @remote_state ||= Internal::RemoteState.new(storage:, work_dir: @work_dir)
  def publisher = @publisher ||= Publisher.new(date: @episode.date)

  def episode_key = "#{@episode.date_tag}_#{@episode.slot}"
  def mp3_filename = File.basename(episode_mp3_path)
  def handoff_work_path(name) = File.join(@work_dir, "handoff_#{name}_#{episode_key}.txt")

  # dist/ に置く成果物のパス。generate と publish で同じ命名規則を共有する。
  def episode_mp3_path = File.join(@dist_dir, "miyamai_news_#{@episode.date_tag}_#{@episode.slot}.mp3")
  def episode_used_path = File.join(@dist_dir, "miyamai_news_#{@episode.date_tag}_#{@episode.slot}.used.txt")
  def episode_transcript_path = File.join(@dist_dir, "miyamai_news_#{@episode.date_tag}_#{@episode.slot}.transcript.txt")
end
