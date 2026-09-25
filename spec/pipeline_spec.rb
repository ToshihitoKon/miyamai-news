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
  let(:handoff_tts_path) { File.join(work_dir, "handoff_tts_script_20260714_afternoon.txt") }
  let(:handoff_script_path) { File.join(work_dir, "handoff_script_20260714_afternoon.txt") }
  let(:handoff_used_path) { File.join(work_dir, "handoff_used_news_20260714_afternoon.txt") }

  let(:generated_tts_path) { File.join(base_dir, "tts_script.txt") }
  let(:generated_script_path) { File.join(base_dir, "script.txt") }
  let(:generated_used_path) { File.join(base_dir, "used.txt") }
  let(:fake_generator) do
    instance_double(ScriptGenerator,
      digest: "news_facts_path", generate: generated_tts_path, fetched_news?: false,
      collect_since_anchor: now, episode_key: "20260714_afternoon",
      used_news_file: generated_used_path, script_file: generated_script_path, collect_stats: nil)
  end
  let(:fake_publisher) { instance_double(Publisher, run: nil, published?: false) }
  let(:fake_voice_synthesizer) { instance_double(VoiceSynthesizer, synthesize: "voice_path") }
  let(:fake_audio_mixer) { instance_double(AudioMixer, mix: nil) }
  let(:fake_remote_state) do
    instance_double(Internal::RemoteState,
      checkout!: :pulled, checked_out_by: nil, ensure_current!: nil, push!: 3, release!: nil)
  end
  let(:fake_handoff) { instance_double(Internal::Handoff, mark_done!: 3) }
  # fake_handoff の exist? は upload! されたら true になる（R2 上に台本一式が揃ったかを模す）。
  let(:handoff_state) { { uploaded: false } }
  let(:phase_timer) { Internal::PhaseTimer.new }

  before do
    allow(ScriptGenerator).to receive(:new).and_return(fake_generator)
    allow(Publisher).to receive(:new).and_return(fake_publisher)
    allow(VoiceSynthesizer).to receive(:new).and_return(fake_voice_synthesizer)
    allow(AudioMixer).to receive(:new).and_return(fake_audio_mixer)
    allow(ScriptGenerator).to receive(:record_used_news_history!)
    # run_publish は mp3 の実在を File.exist? で確認するため、synthesize→publish と
    # 進むテストのために AudioMixer#mix の代わりに実ファイルを置いておく。
    FileUtils.mkdir_p(dist_dir)
    allow(fake_audio_mixer).to receive(:mix) { |_voice_path, output_path| File.write(output_path, "fake mp3") }

    allow(Internal::R2Storage).to receive(:from_config).and_return(instance_double(Internal::R2Storage))
    allow(Internal::RemoteState).to receive(:new).and_return(fake_remote_state)
    allow(Internal::Handoff).to receive(:new).and_return(fake_handoff)
    allow(fake_handoff).to receive(:exist?) { handoff_state[:uploaded] }
    allow(fake_handoff).to receive(:upload!) { handoff_state[:uploaded] = true }
    allow(fake_handoff).to receive(:download!) do |_key, paths|
      paths.each { |name, path| File.write(path, "downloaded #{name}") }
    end
    allow(UsedNewsFormatter).to receive(:ensure_valid!) { |text| text }
    File.write(generated_tts_path, "tts")
    File.write(generated_script_path, "script")
    File.write(generated_used_path, "used")
  end

  after { FileUtils.remove_entry(base_dir) }

  def build_pipeline(args)
    described_class.new(args: args, base_dir: base_dir, work_dir: work_dir, dist_dir: dist_dir, phase_timer: phase_timer)
  end

  def collect_warnings(pipeline)
    messages = []
    allow(pipeline).to receive(:warn) { |msg| messages << msg }
    allow(phase_timer).to receive(:warn) { |msg| messages << msg }
    messages
  end

  def phase_duration_lines(messages)
    header_index = messages.index("phase duration:")
    return [] unless header_index

    messages[(header_index + 1)..].take_while { |m| m.start_with?("  ") }
  end

  describe "Episode非依存の独立コマンド" do
    it "--clean は Episode を作らず EpisodeLogger を configure しない" do
      allow(Internal::EpisodeLogger).to receive(:work_globs).and_return([])
      allow(ScriptGenerator).to receive(:work_globs).and_return([])
      allow(VoiceSynthesizer).to receive(:work_globs).and_return([])
      allow(Publisher).to receive(:new).and_return(instance_double(Publisher, prunable_from_dist: []))

      build_pipeline(clean: true).run

      expect(Internal::EpisodeLogger.instance_variable_get(:@path)).to be_nil
    end

    it "--clean は work/ に取得した handoff の台本も消す" do
      allow(Internal::EpisodeLogger).to receive(:work_globs).and_return([])
      allow(ScriptGenerator).to receive(:work_globs).and_return([])
      allow(VoiceSynthesizer).to receive(:work_globs).and_return([])
      allow(Publisher).to receive(:new).and_return(instance_double(Publisher, prunable_from_dist: []))
      FileUtils.mkdir_p(work_dir)
      File.write(handoff_tts_path, "tts")

      build_pipeline(clean: true).run

      expect(File.exist?(handoff_tts_path)).to be false
    end

    it "--clean は Publisher#prunable_from_dist が削除可と判定した mp3 とその兄弟ファイルだけを dist/ から消す" do
      allow(Internal::EpisodeLogger).to receive(:work_globs).and_return([])
      allow(ScriptGenerator).to receive(:work_globs).and_return([])
      allow(VoiceSynthesizer).to receive(:work_globs).and_return([])
      pruned_mp3 = "miyamai_news_20260601_morning.mp3"
      kept_mp3 = "miyamai_news_20260801_morning.mp3"
      [pruned_mp3, kept_mp3].each do |name|
        File.write(File.join(dist_dir, name), "fake mp3")
        File.write(File.join(dist_dir, name.sub(/\.mp3\z/, ".used.txt")), "fake used")
      end
      allow(Publisher).to receive(:new).and_return(instance_double(Publisher, prunable_from_dist: [pruned_mp3]))

      build_pipeline(clean: true).run

      expect(File.exist?(File.join(dist_dir, pruned_mp3))).to be false
      expect(File.exist?(File.join(dist_dir, pruned_mp3.sub(/\.mp3\z/, ".used.txt")))).to be false
      expect(File.exist?(File.join(dist_dir, kept_mp3))).to be true
      expect(File.exist?(File.join(dist_dir, kept_mp3.sub(/\.mp3\z/, ".used.txt")))).to be true
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

    it "--confirm-fetch は pending が無ければ何もせず、R2 から取り出した作業コピーを手放す" do
      allow(LastFetchStore).to receive(:pending_at).with(work_dir).and_return(nil)

      build_pipeline(confirm_fetch: true).run

      expect(ScriptGenerator).not_to have_received(:record_used_news_history!)
      expect(fake_remote_state).not_to have_received(:push!)
      expect(fake_remote_state).to have_received(:release!)
    end

    it "--confirm-fetch は未完了の実行の作業コピーを引き継いだときは、何もしなくても手放さない" do
      allow(fake_remote_state).to receive(:checkout!).and_return(:resumed)
      allow(LastFetchStore).to receive(:pending_at).with(work_dir).and_return(nil)

      build_pipeline(confirm_fetch: true).run

      expect(fake_remote_state).not_to have_received(:release!)
    end

    it "--confirm-fetch は pending があれば確定して履歴に追記する" do
      pending = Time.utc(2026, 7, 16, 9, 0, 0)
      allow(LastFetchStore).to receive(:pending_at).with(work_dir).and_return(pending)
      allow(LastFetchStore).to receive(:confirm!).with(work_dir: work_dir).and_return("20260716_evening")

      build_pipeline(confirm_fetch: true).run

      expect(fake_remote_state).to have_received(:checkout!)
      expect(ScriptGenerator).to have_received(:record_used_news_history!).with(work_dir: work_dir, episode_key: "20260716_evening")
      expect(fake_remote_state).to have_received(:push!)
    end

    it "--confirm-fetch は collect セクションが欠けていれば confirm! の前に abort する" do
      pending = Time.utc(2026, 7, 16, 9, 0, 0)
      allow(LastFetchStore).to receive(:pending_at).with(work_dir).and_return(pending)
      allow(LastFetchStore).to receive(:confirm!)
      allow(Config).to receive(:validate_sections!).with("collect").and_raise(Config::MissingKeyError, "missing config sections:\n  - collect")

      expect { build_pipeline(confirm_fetch: true).run }.to raise_error(SystemExit)

      expect(LastFetchStore).not_to have_received(:confirm!)
      expect(ScriptGenerator).not_to have_received(:record_used_news_history!)
      expect(fake_remote_state).not_to have_received(:checkout!)
    end

    it "--restore-fetch は restorable でなければ何もしない" do
      allow(LastFetchStore).to receive(:restorable?).with(work_dir).and_return(false)

      expect(LastFetchStore).not_to receive(:restore!)

      build_pipeline(restore_fetch: true).run

      expect(fake_remote_state).not_to have_received(:push!)
    end

    it "--restore-fetch は R2 の状態を取り出して巻き戻し、R2 へ書き戻す" do
      allow(LastFetchStore).to receive(:restorable?).with(work_dir).and_return(true)
      allow(LastFetchStore).to receive(:restore!)
      allow(LastFetchStore).to receive(:pending_at).and_return(nil)

      build_pipeline(restore_fetch: true).run

      expect(fake_remote_state).to have_received(:checkout!)
      expect(LastFetchStore).to have_received(:restore!).with(work_dir: work_dir)
      expect(fake_remote_state).to have_received(:push!)
    end

    it "--clean は未完了の作業コピーの取得元 revision も消す（次回は R2 から取り直す）" do
      allow(Internal::EpisodeLogger).to receive(:work_globs).and_return([])
      allow(ScriptGenerator).to receive(:work_globs).and_return([])
      allow(VoiceSynthesizer).to receive(:work_globs).and_return([])
      allow(Publisher).to receive(:new).and_return(instance_double(Publisher, prunable_from_dist: []))
      FileUtils.mkdir_p(work_dir)
      marker = File.join(work_dir, Internal::RemoteState::BASE_REVISION_FILE)
      File.write(marker, "rev")

      build_pipeline(clean: true).run

      expect(File.exist?(marker)).to be false
    end
  end

  describe "Episode依存の経路" do
    it "--publish-only は run_publish の後に handoff を処理済みにし、収集 window には触らない" do
      File.write(mp3_path, "fake mp3")
      allow(LastFetchStore).to receive(:confirm!)

      build_pipeline(publish_only: true, date: now, slot: "afternoon").run

      expect(fake_publisher).to have_received(:run).with(mp3_path, nil, nil)
      expect(fake_handoff).to have_received(:mark_done!).with("20260714_afternoon")
      expect(LastFetchStore).not_to have_received(:confirm!)
    end

    it "--publish-only は新規収集をしないため ScriptGenerator も R2 の状態取得も行わない" do
      File.write(mp3_path, "fake mp3")

      build_pipeline(publish_only: true, date: now, slot: "afternoon").run

      expect(ScriptGenerator).not_to have_received(:new)
      expect(fake_remote_state).not_to have_received(:checkout!)
    end

    it "--digest-only は R2 の状態を取得してから digest するが、状態は書き戻さない" do
      build_pipeline(digest_only: true, date: now, slot: "afternoon").run

      expect(fake_remote_state).to have_received(:checkout!).ordered
      expect(ScriptGenerator).to have_received(:new).ordered
      expect(fake_generator).to have_received(:digest)
      expect(fake_remote_state).not_to have_received(:push!)
      expect(fake_handoff).not_to have_received(:upload!)
    end

    it "--script-only は digest してから generate(format: false) を呼び、digest/writerの2フェーズとして計測する" do
      pipeline = build_pipeline(script_only: true, date: now, slot: "afternoon")
      messages = collect_warnings(pipeline)

      pipeline.run

      expect(fake_generator).to have_received(:digest)
      expect(fake_generator).to have_received(:generate).with(format: false)
      expect(fake_remote_state).not_to have_received(:push!)
      duration_labels = phase_duration_lines(messages).map { |l| l[/\A  (\w+):/, 1] }
      expect(duration_labels).to eq(%w[digest writer])
      expect(messages).to include("news facts: news_facts_path")
    end

    it "--date/--slot を省略した実行は、ローカルのタイムゾーンが JST でなければ abort する" do
      allow(Time).to receive(:now).and_return(Time.new(2026, 7, 14, 3, 0, 0, "+00:00"))

      expect { build_pipeline({}).run }.to raise_error(SystemExit)

      expect(fake_remote_state).not_to have_received(:checkout!)
      expect(fake_handoff).not_to have_received(:exist?)
    end

    it "--date と --slot を両方指定すればタイムゾーンによらず実行できる" do
      allow(Time).to receive(:now).and_return(Time.new(2026, 7, 14, 3, 0, 0, "+00:00"))

      build_pipeline(digest_only: true, date: now, slot: "afternoon").run

      expect(fake_generator).to have_received(:digest)
    end

    it "作業コピーを取り出すときは、この回の episode_key を owner として渡す" do
      build_pipeline(digest_only: true, date: now, slot: "afternoon").run

      expect(fake_remote_state).to have_received(:checkout!).with(owner: "20260714_afternoon")
    end

    it "別の回が残した作業コピーを引き継ぐときは、その回を警告する" do
      allow(fake_remote_state).to receive_messages(checked_out_by: "20260714_morning", checkout!: :resumed)
      pipeline = build_pipeline(digest_only: true, date: now, slot: "afternoon")
      messages = collect_warnings(pipeline)

      pipeline.run

      expect(messages).to include(a_string_including("left by 20260714_morning"))
    end

    it "pipeline.mode: digest のフラグなし実行は digest までで止まり、状態も handoff も書き込まない" do
      allow(Config).to receive(:mode).and_return("digest")

      build_pipeline(date: now, slot: "afternoon").run

      expect(fake_generator).to have_received(:digest)
      expect(fake_generator).not_to have_received(:generate)
      expect(fake_remote_state).not_to have_received(:push!)
      expect(fake_handoff).not_to have_received(:upload!)
    end

    it "R2 の状態が空なら ScriptGenerator を作らずに abort する" do
      allow(fake_remote_state).to receive(:checkout!).and_raise(Internal::RemoteState::Missing, "no pipeline state")

      expect { build_pipeline(date: now, slot: "afternoon").run }.to raise_error(SystemExit)

      expect(ScriptGenerator).not_to have_received(:new)
    end

    context "フラグなし実行で R2 にこの回の handoff が無い場合" do
      it "生成した台本一式を R2 に置いてから、R2 経由で合成して publish し、handoff を処理済みにする" do
        allow(LastFetchStore).to receive(:confirm!).with(work_dir: work_dir).and_return(nil)
        events = []
        allow(fake_remote_state).to receive(:checkout!) { events << :checkout }
        allow(fake_remote_state).to receive(:ensure_current!) { events << :ensure_current }
        allow(LastFetchStore).to receive(:confirm!) { events << :confirm }
        allow(fake_remote_state).to receive(:push!) { events << :push }
        allow(fake_handoff).to receive(:upload!) do
          handoff_state[:uploaded] = true
          events << :upload
        end
        allow(fake_handoff).to receive(:download!) do |_key, paths|
          paths.each { |name, path| File.write(path, "downloaded #{name}") }
          events << :download
        end
        allow(fake_publisher).to receive(:run) { events << :publish }
        allow(fake_handoff).to receive(:mark_done!) do
          events << :done
          3
        end

        build_pipeline(date: now, slot: "afternoon").run

        expect(events).to eq([:checkout, :ensure_current, :confirm, :push, :upload, :download, :publish, :done])
        expect(fake_generator).to have_received(:generate).with(no_args)
        expect(fake_handoff).to have_received(:upload!).with(
          "20260714_afternoon", tts_script: "tts", script: "script", used_news: "used"
        )
        expect(fake_handoff).to have_received(:download!).with(
          "20260714_afternoon", tts_script: handoff_tts_path, script: handoff_script_path, used_news: handoff_used_path
        )
        expect(File.read(used_path)).to eq("downloaded used_news")
        expect(File.read(transcript_path)).to eq("downloaded script")
        expect(fake_voice_synthesizer).to have_received(:synthesize).with(handoff_tts_path)
        expect(fake_handoff).to have_received(:mark_done!).with("20260714_afternoon")
      end

      it "アップロードする used_news は UsedNewsFormatter で検証・修復した内容にする" do
        allow(LastFetchStore).to receive(:confirm!).and_return(nil)
        allow(UsedNewsFormatter).to receive(:ensure_valid!).with("used").and_return("repaired used")

        build_pipeline(date: now, slot: "afternoon").run

        expect(fake_handoff).to have_received(:upload!).with(anything, hash_including(used_news: "repaired used"))
      end

      it "fetched_news? が true なら confirm_immediately! して履歴に記録し、状態を書き戻してから upload する" do
        allow(fake_generator).to receive(:fetched_news?).and_return(true)
        allow(LastFetchStore).to receive(:confirm_immediately!)
        allow(LastFetchStore).to receive(:confirm!)

        build_pipeline(date: now, slot: "afternoon").run

        expect(LastFetchStore).to have_received(:confirm_immediately!).with(work_dir: work_dir, at: now).ordered
        expect(ScriptGenerator).to have_received(:record_used_news_history!)
          .with(work_dir: work_dir, episode_key: "20260714_afternoon").ordered
        expect(fake_remote_state).to have_received(:push!).ordered
        expect(fake_handoff).to have_received(:upload!).ordered
        expect(LastFetchStore).not_to have_received(:confirm!)
      end

      it "fetched_news? が false なら pending を confirm! して、その回を履歴に記録する" do
        allow(LastFetchStore).to receive(:confirm!).with(work_dir: work_dir).and_return("20260714_morning")

        build_pipeline(date: now, slot: "afternoon").run

        expect(ScriptGenerator).to have_received(:record_used_news_history!)
          .with(work_dir: work_dir, episode_key: "20260714_morning")
      end

      it "内部状態の書き戻し後・アップロード前に落ちても、再実行で台本一式を置き直せる" do
        upload_attempts = 0
        allow(fake_handoff).to receive(:upload!) do
          upload_attempts += 1
          raise Aws::S3::Errors::ServiceError.new(nil, "boom") if upload_attempts == 1

          handoff_state[:uploaded] = true
        end
        allow(LastFetchStore).to receive(:confirm!).and_return("20260714_afternoon", nil)

        expect { build_pipeline(handoff_only: true, date: now, slot: "afternoon").run }
          .to raise_error(Aws::S3::Errors::ServiceError)
        build_pipeline(handoff_only: true, date: now, slot: "afternoon").run

        expect(handoff_state[:uploaded]).to be true
        expect(fake_remote_state).to have_received(:push!).twice
        expect(ScriptGenerator).to have_received(:record_used_news_history!)
          .with(work_dir: work_dir, episode_key: "20260714_afternoon").once
        expect(ScriptGenerator).to have_received(:record_used_news_history!).with(work_dir: work_dir, episode_key: nil).once
      end

      it "公開台帳に既にこの回があれば、生成も合成もせずに abort する" do
        allow(fake_publisher).to receive(:published?).with("miyamai_news_20260714_afternoon.mp3").and_return(true)

        expect { build_pipeline(date: now, slot: "afternoon").run }.to raise_error(SystemExit)

        expect(ScriptGenerator).not_to have_received(:new)
        expect(fake_handoff).not_to have_received(:upload!)
        expect(fake_publisher).not_to have_received(:run)
      end

      it "生成中に別の実行がこの回の handoff を置いていたら、アップロードせずに abort する" do
        allow(fake_generator).to receive(:generate) do
          handoff_state[:uploaded] = true
          generated_tts_path
        end

        expect { build_pipeline(date: now, slot: "afternoon").run }.to raise_error(SystemExit)

        expect(fake_handoff).not_to have_received(:upload!)
        expect(fake_remote_state).not_to have_received(:push!)
      end

      it "生成中に別の実行が R2 の状態を更新していたら、アップロードせずに abort する" do
        allow(fake_remote_state).to receive(:ensure_current!).and_raise(Internal::RemoteState::Conflict, "conflict")

        expect { build_pipeline(date: now, slot: "afternoon").run }.to raise_error(SystemExit)

        expect(fake_handoff).not_to have_received(:upload!)
        expect(fake_remote_state).not_to have_received(:push!)
      end
    end

    it "フラグなし実行で R2 にこの回の handoff があれば、生成も状態取得もせずに合成・publish する" do
      handoff_state[:uploaded] = true

      build_pipeline(date: now, slot: "afternoon").run

      expect(ScriptGenerator).not_to have_received(:new)
      expect(fake_remote_state).not_to have_received(:checkout!)
      expect(fake_handoff).to have_received(:download!)
      expect(fake_publisher).to have_received(:run)
      expect(fake_handoff).to have_received(:mark_done!)
    end

    it "--handoff-only は R2 へのアップロードと状態の書き戻しで止まる（合成も publish もしない）" do
      allow(LastFetchStore).to receive(:confirm!).and_return(nil)

      build_pipeline(handoff_only: true, date: now, slot: "afternoon").run

      expect(fake_handoff).to have_received(:upload!)
      expect(fake_remote_state).to have_received(:push!)
      expect(fake_handoff).not_to have_received(:download!)
      expect(fake_publisher).not_to have_received(:run)
    end

    it "音声合成に失敗したら、dist/ に used / transcript を書き出さない" do
      handoff_state[:uploaded] = true
      allow(fake_voice_synthesizer).to receive(:synthesize).and_raise(SystemExit)

      expect { build_pipeline(date: now, slot: "afternoon").run }.to raise_error(SystemExit)

      expect(File.exist?(used_path)).to be false
      expect(File.exist?(transcript_path)).to be false
    end

    it "--handoff-only は pipeline.mode が digest でも実行できる（音声合成の config を要求しない）" do
      allow(Config).to receive(:mode).and_return("digest")
      allow(LastFetchStore).to receive(:confirm!).and_return(nil)

      build_pipeline(handoff_only: true, date: now, slot: "afternoon").run

      expect(fake_handoff).to have_received(:upload!)
    end

    it "アップロード時に修復した used_news を work/ にも書き戻し、紹介済み履歴はそれを元に記録される" do
      allow(LastFetchStore).to receive(:confirm!).and_return(nil)
      allow(UsedNewsFormatter).to receive(:ensure_valid!).and_return("repaired used")

      build_pipeline(handoff_only: true, date: now, slot: "afternoon").run

      expect(File.read(generated_used_path)).to eq("repaired used")
    end

    it "--synthesize-only は R2 経由で synthesize までで止まる（publish も handoff の処理済み化もしない）" do
      handoff_state[:uploaded] = true

      build_pipeline(synthesize_only: true, date: now, slot: "afternoon").run

      expect(fake_handoff).to have_received(:download!)
      expect(fake_publisher).not_to have_received(:run)
      expect(fake_handoff).not_to have_received(:mark_done!)
    end
  end

  describe "フェーズ所要時間のサマリ出力" do
    before { allow(LastFetchStore).to receive(:confirm!).and_return(nil) }

    it "正常終了時は digest/writer/voice/publish の4行が出力され、いずれも(failed)が付かない" do
      pipeline = build_pipeline(date: now, slot: "afternoon")
      messages = collect_warnings(pipeline)

      pipeline.run

      expect(messages).to include("phase duration:")
      duration_lines = phase_duration_lines(messages)
      expect(duration_lines.size).to eq(4)
      expect(duration_lines).to all(match(/\A  (digest|writer|voice|publish): [\d.]+s\z/))
      expect(duration_lines.map { |l| l[/\A  (\w+):/, 1] }).to eq(%w[digest writer voice publish])
    end

    it "publish フェーズの abort 後にもサマリが出力され、失敗したフェーズにだけ(failed)が付く" do
      # run_publish 冒頭の mp3 未検出チェックで abort させるため、mix によるファイル作成を止める。
      allow(fake_audio_mixer).to receive(:mix)

      pipeline = build_pipeline(date: now, slot: "afternoon")
      messages = collect_warnings(pipeline)

      expect { pipeline.run }.to raise_error(SystemExit)

      expect(messages).to include("phase duration:")
      duration_lines = phase_duration_lines(messages)
      expect(duration_lines.map { |l| l[/\A  (\w+):/, 1] }).to eq(%w[digest writer voice publish])
      expect(duration_lines[0..2]).to all(satisfy { |l| !l.include?("(failed)") })
      expect(duration_lines.last).to match(/\A  publish: [\d.]+s \(failed\)\z/)
    end

    it "--clean のような独立コマンドではサマリが出力されない" do
      allow(Internal::EpisodeLogger).to receive(:work_globs).and_return([])
      allow(ScriptGenerator).to receive(:work_globs).and_return([])
      allow(VoiceSynthesizer).to receive(:work_globs).and_return([])
      allow(Publisher).to receive(:new).and_return(instance_double(Publisher, prunable_from_dist: []))

      pipeline = build_pipeline(clean: true)
      messages = collect_warnings(pipeline)

      pipeline.run

      expect(messages).not_to include("phase duration:")
      expect(phase_duration_lines(messages)).to be_empty
    end
  end

  describe ".target_mode_for" do
    after { Config.path = File.expand_path("fixtures/config.yaml", __dir__) }

    it "returns nil for the independent commands" do
      [:clean, :clean_archive, :ui_only, :confirm_fetch, :restore_fetch].each do |flag|
        expect(Pipeline.target_mode_for(flag => true)).to be_nil
      end
    end

    it "returns digest for --digest-only" do
      expect(Pipeline.target_mode_for(digest_only: true)).to eq("digest")
    end

    it "returns synthesize for --script-only, --synthesize-only and --handoff-only" do
      expect(Pipeline.target_mode_for(script_only: true)).to eq("synthesize")
      expect(Pipeline.target_mode_for(synthesize_only: true)).to eq("synthesize")
      expect(Pipeline.target_mode_for(handoff_only: true)).to eq("synthesize")
    end

    it "falls back to Config.mode for --publish-only and no flags" do
      expect(Pipeline.target_mode_for(publish_only: true)).to eq("publish")
      expect(Pipeline.target_mode_for({})).to eq("publish")
    end
  end

  describe ".reaches?" do
    after { Config.path = File.expand_path("fixtures/config.yaml", __dir__) }

    it "returns false for the independent commands, which have no target mode" do
      expect(Pipeline.reaches?("digest", clean: true)).to be false
    end

    it "compares against Config::MODE_ORDER" do
      expect(Pipeline.reaches?("digest", digest_only: true)).to be true
      expect(Pipeline.reaches?("publish", digest_only: true)).to be false
    end

    it "returns true for --publish-only and no flags when pipeline.mode is publish" do
      expect(Pipeline.reaches?("publish", publish_only: true)).to be true
      expect(Pipeline.reaches?("publish", {})).to be true
    end

    it "returns false when pipeline.mode is below the requested mode" do
      Config.path = File.expand_path("fixtures/config_digest.yaml", __dir__)

      expect(Pipeline.reaches?("publish", {})).to be false
    end
  end
end
