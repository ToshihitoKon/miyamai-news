# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require_relative "../../lib/episode"
require_relative "../../lib/slot"
require_relative "../../lib/voice_synthesizer"
require_relative "../../lib/internal/config"
require_relative "../../lib/internal/episode_logger"
require_relative "../../lib/internal/restricted_agy"
require_relative "tts_reading_check/judgement"
require_relative "tts_reading_check/prompt"
require_relative "tts_reading_check/report"
require_relative "tts_reading_check/transcript"

class TtsReadingCheck
  HANDOFF_TTS_SCRIPT_PREFIX = "handoff_tts_script_"
  TRANSCRIBE_BATCH_SIZE = 10

  def self.latest_tts_script(work_dir)
    paths = Dir.glob(File.join(work_dir, "#{HANDOFF_TTS_SCRIPT_PREFIX}*.txt"))
    sort_keys = paths.to_h { |path| [path, Slot.sort_key_from_filename(File.basename(path, ".txt"))] }.compact
    sort_keys.max_by { |_path, sort_key| sort_key }&.first
  end

  def initialize(tts_script_path:, work_dir:, report_path:, retranscribe: false, resynthesize: false)
    @tts_script_path = tts_script_path
    @work_dir = work_dir
    @report_path = report_path
    @retranscribe = retranscribe
    @resynthesize = resynthesize
  end

  def run
    FileUtils.rm_f(@report_path)
    Config.validate_sections!("voicepeak", "ai_agent")
    abort "VOICEPEAK not found: #{Config.voicepeak.bin}" unless File.executable?(Config.voicepeak.bin)
    abort "ai_agent.bin must be agy: #{Config.ai_agent.bin}" unless Internal::RestrictedAgy.configured?
    abort "#{Internal::RestrictedAgy::UNSAFE_PATH_MESSAGE}: #{wav_dir}" unless Internal::RestrictedAgy.rule_safe_path?(wav_dir)

    chunks = split_script
    Internal::EpisodeLogger.configure(log_path)
    wav_paths = prepare_wavs(chunks)
    chunk_texts = chunks.map { |chunk| chunk[:text].gsub(/\s*\n\s*/, " ") }
    transcripts, reused_batch_count, batch_count = transcribe(wav_paths)
    findings = judge(chunk_texts, transcripts)

    File.write(@report_path, Report.render(
      tts_script_path: @tts_script_path, generated_at: Time.now, chunk_texts: chunk_texts,
      transcripts: transcripts, wav_paths: wav_paths, findings: findings,
      reused_batch_count: reused_batch_count, batch_count: batch_count
    ))
    @report_path
  end

  private

  def key
    @key ||= begin
      name = File.basename(@tts_script_path, ".*").delete_prefix(HANDOFF_TTS_SCRIPT_PREFIX)
      safe_name = Internal::RestrictedAgy.rule_safe_name(name)
      safe_name == name ? name : "#{safe_name}_#{Digest::SHA256.hexdigest(name)[0, 8]}"
    end
  end

  def wav_dir = File.join(@work_dir, "tts_check_#{key}")
  def transcribe_output_path(batch) = File.join(@work_dir, "tts_check_#{key}.transcribe.#{batch}.txt")
  def transcribe_inputs_path(batch) = File.join(@work_dir, "tts_check_#{key}.transcribe.#{batch}.inputs.txt")
  def previous_output_path(batch) = File.join(@work_dir, "tts_check_#{key}.transcribe.#{batch}.previous.txt")
  def previous_inputs_path(batch) = File.join(@work_dir, "tts_check_#{key}.transcribe.#{batch}.previous.inputs.txt")
  def judge_output_path = File.join(@work_dir, "tts_check_#{key}.judge.txt")
  def log_path = File.join(@work_dir, "tts_check_#{key}.log")

  def synthesizer
    @synthesizer ||= VoiceSynthesizer.new(work_dir: @work_dir, episode: Episode.new)
  end

  def split_script
    chunks = synthesizer.split_chunks(File.read(@tts_script_path))
    abort "empty script: #{@tts_script_path}" if chunks.empty?
    chunks
  end

  def prepare_wavs(chunks)
    FileUtils.rm_rf(wav_dir) if @resynthesize
    wav_paths = synthesizer.synthesize_wavs(chunks, wav_dir)
    FileUtils.rm_rf(Dir.children(wav_dir).map { |name| File.join(wav_dir, name) } - wav_paths)
    wav_paths
  rescue VoiceSynthesizer::SynthesisError => e
    rerun = @resynthesize ? "rerun without --resynthesize" : "rerun"
    abort "synthesis failed: #{e.message} (#{rerun} to continue from the wavs synthesized so far)"
  end

  # 戻り値は [全チャンクの書き起こし, 保存済みの書き起こしを使い回したまとまりの数, まとまりの数]。
  def transcribe(wav_paths)
    batches = wav_paths.each_slice(TRANSCRIBE_BATCH_SIZE).to_a
    results = batches.each_with_index.map do |batch_wav_paths, i|
      transcribe_batch(i + 1, batch_wav_paths, batches.size)
    end

    [results.flat_map(&:first), results.count(&:last), batches.size]
  end

  def transcribe_batch(batch, wav_paths, batch_count)
    inputs = transcription_inputs(wav_paths)
    saved_output = Transcript.load_raw_matching(transcribe_output_path(batch), transcribe_inputs_path(batch), inputs) unless @retranscribe
    if saved_output
      transcripts = parse_or_warn(saved_output, wav_paths.size,
        "#{transcribe_output_path(batch)} is unusable, transcribing batch #{batch}/#{batch_count} again")
      return [transcripts, true] if transcripts
    end

    output, kept_previous = transcribe_with_agy(batch, wav_paths, inputs, batch_count)
    [parse_transcription(output, batch, wav_paths.size, kept_previous:), false]
  end

  def parse_or_warn(output, expected_count, consequence)
    Transcript.parse(output, expected_count)
  rescue Transcript::Error => e
    warn "#{e.message} (#{consequence})"
    nil
  end

  def transcription_inputs(wav_paths)
    template_digest = Digest::SHA256.file(Prompt.path(Prompt::TRANSCRIBE)).hexdigest
    ["model #{Config.ai_agent.model}", "prompt #{template_digest}",
     *wav_paths.map { |path| "wav #{Digest::SHA256.file(path).hexdigest}" }]
  end

  # 戻り値は [agy の出力, 前回の書き起こしを previous に移したか]。
  def transcribe_with_agy(batch, wav_paths, inputs, batch_count)
    prompt = Prompt.render(Prompt::TRANSCRIBE, wav_paths: wav_paths)
    message = "transcribing #{wav_paths.size} chunks (#{batch}/#{batch_count})"
    output = run_transcription(message, prompt)
    retry_note = "transcribing batch #{batch}/#{batch_count} once more"
    output = run_transcription("#{message}, once more", prompt) unless parse_or_warn(output, wav_paths.size, retry_note)
    kept_previous = usable_saved_transcription?(batch)
    keep_previous_transcription(batch) if kept_previous
    Transcript.save_raw(transcribe_output_path(batch), transcribe_inputs_path(batch), output: output, inputs: inputs)
    [output, kept_previous]
  rescue Internal::RestrictedAgy::Error => e
    rerun = @retranscribe ? "rerun without --retranscribe" : "rerun"
    saved = batch > 1 ? " (the first #{batch - 1} batches are saved; #{rerun} to reuse them)" : ""
    abort "transcription failed: #{e.message}#{saved}"
  end

  def run_transcription(message, prompt)
    Internal::RestrictedAgy.run(message, prompt, model: Config.ai_agent.model, workdir: wav_dir, readable_dir: wav_dir)
  end

  def usable_saved_transcription?(batch)
    return false unless File.exist?(transcribe_output_path(batch)) && File.exist?(transcribe_inputs_path(batch))

    chunk_count = File.read(transcribe_inputs_path(batch)).split("\n").count { |line| line.start_with?("wav ") }
    Transcript.parse(File.read(transcribe_output_path(batch)), chunk_count)
    true
  rescue Transcript::Error
    false
  end

  def keep_previous_transcription(batch)
    FileUtils.mv(transcribe_output_path(batch), previous_output_path(batch))
    FileUtils.mv(transcribe_inputs_path(batch), previous_inputs_path(batch))
  end

  def parse_transcription(output, batch, expected_count, kept_previous:)
    Transcript.parse(output, expected_count)
  rescue Transcript::Error => e
    rerun = @retranscribe ? "rerun without --retranscribe" : "rerun"
    previous = kept_previous ? "; the transcription before it is kept in #{previous_output_path(batch)}" : ""
    abort "transcription output is unusable: #{e.message} " \
          "(fix #{transcribe_output_path(batch)} by hand and #{rerun}, " \
          "or just #{rerun} to transcribe this batch again#{previous})"
  end

  def judge(chunk_texts, transcripts)
    pairs = chunk_texts.each_with_index.map { |text, i| { number: i + 1, text: text, heard: transcripts[i] } }
    prompt = Prompt.render(Prompt::JUDGE, pairs: pairs)
    output = Dir.mktmpdir("tts_check_judge") do |empty_dir|
      Internal::RestrictedAgy.run("judging readings", prompt,
        model: Config.ai_agent.model, workdir: empty_dir, readable_dir: nil)
    end
    File.write(judge_output_path, output)

    Judgement.parse(output, pairs.size)
  rescue Internal::RestrictedAgy::Error => e
    abort "judgement failed: #{e.message} (saved transcriptions: #{transcribe_output_path('*')})"
  rescue Judgement::Error => e
    abort "judgement output is unusable: #{e.message} (raw output: #{judge_output_path}; " \
          "a rerun judges again with agy and reuses the saved transcription)"
  end
end
