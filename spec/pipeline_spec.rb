# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "pipeline"

RSpec.describe Pipeline do
  let(:base_dir) { Dir.mktmpdir }
  let(:work_dir) { File.join(base_dir, "work") }
  let(:dist_dir) { File.join(base_dir, "dist") }
  let(:now) { Time.utc(2026, 7, 14, 12, 0, 0) } # afternoon slot
  let(:mp3_path) { File.join(dist_dir, "miyamai_news_20260714_afternoon.mp3") }
  let(:used_path) { File.join(dist_dir, "miyamai_news_20260714_afternoon.used.txt") }
  let(:transcript_path) { File.join(dist_dir, "miyamai_news_20260714_afternoon.transcript.txt") }

  let(:fake_generator) do
    instance_double(ScriptGenerator,
      digest: "news_facts_path", generate: "tts_script_path", fetched_news?: false,
      collect_since_anchor: now, episode_key: "20260714_afternoon",
      used_news_file: "used_news_file", script_file: "script_file")
  end
  let(:fake_publisher) { instance_double(Publisher, run: nil) }
  let(:fake_voice_synthesizer) { instance_double(VoiceSynthesizer, synthesize: "voice_path") }
  let(:fake_audio_mixer) { instance_double(AudioMixer, mix: nil) }

  before do
    allow(ScriptGenerator).to receive(:new).and_return(fake_generator)
    allow(Publisher).to receive(:new).and_return(fake_publisher)
    allow(VoiceSynthesizer).to receive(:new).and_return(fake_voice_synthesizer)
    allow(AudioMixer).to receive(:new).and_return(fake_audio_mixer)
    allow(ScriptGenerator).to receive(:record_used_news_history!)
    allow(FileUtils).to receive(:cp) # run_synthesize が dist/ へコピーする際、実ファイルが無いため実処理はスキップする
    # run_publish は mp3 の実在を File.exist? で確認するため、synthesize→publish と
    # 進むテストのために AudioMixer#mix の代わりに実ファイルを置いておく。
    FileUtils.mkdir_p(dist_dir)
    allow(fake_audio_mixer).to receive(:mix) { |_voice_path, output_path| File.write(output_path, "fake mp3") }
  end

  after { FileUtils.remove_entry(base_dir) }

  def build_pipeline(args)
    described_class.new(args: args, base_dir: base_dir, work_dir: work_dir, dist_dir: dist_dir)
  end

  describe "Episode非依存の独立コマンド" do
    it "--clean は Episode を作らず EpisodeLogger を configure しない" do
      allow(Internal::EpisodeLogger).to receive(:work_globs).and_return([])
      allow(ScriptGenerator).to receive(:work_globs).and_return([])
      allow(VoiceSynthesizer).to receive(:work_globs).and_return([])
      allow(Publisher).to receive(:new).and_return(instance_double(Publisher, object_exists?: false))

      build_pipeline(clean: true).run

      expect(Internal::EpisodeLogger.instance_variable_get(:@path)).to be_nil
    end

    it "--ui-only は republish_ui のみ呼ぶ" do
      publisher = instance_double(Publisher, republish_ui: nil)
      allow(Publisher).to receive(:new).and_return(publisher)

      build_pipeline(ui_only: true).run

      expect(publisher).to have_received(:republish_ui)
      expect(Internal::EpisodeLogger.instance_variable_get(:@path)).to be_nil
    end

    it "--clean-archive は clean_archive のみ呼ぶ" do
      publisher = instance_double(Publisher, clean_archive: nil)
      allow(Publisher).to receive(:new).and_return(publisher)

      build_pipeline(clean_archive: true).run

      expect(publisher).to have_received(:clean_archive)
    end

    it "--confirm-fetch は pending が無ければ何もしない" do
      allow(LastFetchStore).to receive(:pending_at).with(work_dir).and_return(nil)

      build_pipeline(confirm_fetch: true).run

      expect(ScriptGenerator).not_to have_received(:record_used_news_history!)
    end

    it "--confirm-fetch は pending があれば確定して履歴に追記する" do
      pending = Time.utc(2026, 7, 16, 9, 0, 0)
      allow(LastFetchStore).to receive(:pending_at).with(work_dir).and_return(pending)
      allow(LastFetchStore).to receive(:confirm!).with(work_dir: work_dir).and_return("20260716_evening")

      build_pipeline(confirm_fetch: true).run

      expect(ScriptGenerator).to have_received(:record_used_news_history!).with(work_dir: work_dir, episode_key: "20260716_evening")
    end

    it "--restore-fetch は restorable でなければ何もしない" do
      allow(LastFetchStore).to receive(:restorable?).with(work_dir).and_return(false)

      expect(LastFetchStore).not_to receive(:restore!)

      build_pipeline(restore_fetch: true).run
    end
  end

  describe "Episode依存の経路" do
    it "--publish-only は run_publish の後に confirm! と履歴追記を行う（pending昇格のみ）" do
      FileUtils.mkdir_p(dist_dir)
      File.write(mp3_path, "fake mp3")
      allow(LastFetchStore).to receive(:confirm!).with(work_dir: work_dir).and_return("20260714_afternoon")

      build_pipeline(publish_only: true, date: now).run

      expect(fake_publisher).to have_received(:run).with(mp3_path, nil, nil)
      expect(LastFetchStore).to have_received(:confirm!).with(work_dir: work_dir)
      expect(ScriptGenerator).to have_received(:record_used_news_history!).with(work_dir: work_dir, episode_key: "20260714_afternoon")
    end

    it "--publish-only は新規収集をしないため ScriptGenerator を生成しない" do
      FileUtils.mkdir_p(dist_dir)
      File.write(mp3_path, "fake mp3")
      allow(LastFetchStore).to receive(:confirm!).with(work_dir: work_dir).and_return(nil)

      build_pipeline(publish_only: true, date: now).run

      expect(ScriptGenerator).not_to have_received(:new)
    end

    it "--digest-only は digest を実行し fetched_news? が false なら pending 化しない" do
      allow(fake_generator).to receive(:fetched_news?).and_return(false)
      allow(LastFetchStore).to receive(:mark_pending!)

      build_pipeline(digest_only: true, date: now).run

      expect(fake_generator).to have_received(:digest)
      expect(LastFetchStore).not_to have_received(:mark_pending!)
    end

    it "--digest-only は fetched_news? が true なら pending 化する" do
      allow(fake_generator).to receive(:fetched_news?).and_return(true)
      allow(LastFetchStore).to receive(:mark_pending!)

      build_pipeline(digest_only: true, date: now).run

      expect(LastFetchStore).to have_received(:mark_pending!).with(
        work_dir: work_dir, at: now, episode_key: "20260714_afternoon"
      )
    end

    it "--digest-only は facts パスと config.notify.targets を NotifyDispatcher へ渡す" do
      allow(Internal::Notifiers::NotifyDispatcher).to receive(:run)
      allow(Config).to receive(:notify).and_return(instance_double(Internal::Config::Notify, targets: ["slack"]))

      build_pipeline(digest_only: true, date: now).run

      expect(Internal::Notifiers::NotifyDispatcher).to have_received(:run).with(
        ["slack"], facts_path: "news_facts_path", episode_label: a_string_matching(/2026/)
      )
    end

    it "--digest-only は config.notify が未設定なら空配列を NotifyDispatcher へ渡す" do
      allow(Internal::Notifiers::NotifyDispatcher).to receive(:run)
      allow(Config).to receive(:notify).and_return(nil)

      build_pipeline(digest_only: true, date: now).run

      expect(Internal::Notifiers::NotifyDispatcher).to have_received(:run).with(
        [], facts_path: "news_facts_path", episode_label: anything
      )
    end

    it "--script-only は generate(format: false) を呼ぶ" do
      build_pipeline(script_only: true, date: now).run

      expect(fake_generator).to have_received(:generate).with(format: false)
    end

    it "フラグなし実行は pipeline.mode(publish) まで digest→synthesize→publish を進める" do
      allow(fake_generator).to receive(:fetched_news?).and_return(false)
      allow(LastFetchStore).to receive(:confirm!).with(work_dir: work_dir).and_return("20260714_afternoon")

      build_pipeline({}.merge(date: now)).run

      expect(fake_generator).to have_received(:digest)
      expect(fake_generator).to have_received(:generate).with(no_args)
      expect(fake_publisher).to have_received(:run)
      expect(LastFetchStore).to have_received(:confirm!).with(work_dir: work_dir)
    end

    it "フラグなし実行で fetched_news? が true なら confirm_immediately! を使う（confirm!は使わない）" do
      allow(fake_generator).to receive(:fetched_news?).and_return(true)
      allow(LastFetchStore).to receive(:confirm_immediately!)
      allow(LastFetchStore).to receive(:confirm!)

      build_pipeline({}.merge(date: now)).run

      expect(LastFetchStore).to have_received(:confirm_immediately!).with(work_dir: work_dir, at: now)
      expect(LastFetchStore).not_to have_received(:confirm!)
      expect(ScriptGenerator).to have_received(:record_used_news_history!).with(work_dir: work_dir, episode_key: "20260714_afternoon")
    end

    it "--synthesize-only は synthesize までで止まり pending 化する（publish は呼ばない）" do
      allow(fake_generator).to receive(:fetched_news?).and_return(true)
      allow(LastFetchStore).to receive(:mark_pending!)

      build_pipeline(synthesize_only: true, date: now).run

      expect(fake_generator).to have_received(:generate).with(no_args)
      expect(fake_publisher).not_to have_received(:run)
      expect(LastFetchStore).to have_received(:mark_pending!).with(
        work_dir: work_dir, at: now, episode_key: "20260714_afternoon"
      )
    end
  end
end
