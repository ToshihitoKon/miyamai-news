# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "date"
require "csv"
require "publisher"

RSpec.describe Publisher do
  let(:work_dir) { Dir.mktmpdir }
  let(:mp3_path) { File.join(work_dir, "miyamai_news_20260714_afternoon.mp3") }
  let(:used_path) { File.join(work_dir, "miyamai_news_20260714_afternoon.used.txt") }
  let(:transcript_path) { File.join(work_dir, "miyamai_news_20260714_afternoon.transcript.txt") }

  before do
    File.write(mp3_path, "fake mp3")
    File.write(used_path, "## 生成AI\n### [Title A](https://example.com/a)\n   要約です。\n   (2026-07-14 / SourceA)\n")
    File.write(transcript_path, "宮舞モカです。\n")
  end

  after { FileUtils.remove_entry(work_dir) }

  describe "#run" do
    def stub_gcloud_for_first_publish(publisher)
      commands = []
      contents = {}
      # 初回公開シナリオ: archives.csv はまだ GCS に存在しない(object_exists? が false)。
      no_objects_status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(["", "One or more URLs matched no objects.", no_objects_status])

      allow(publisher).to receive(:system) do |*args, **_opts|
        commands << args.map(&:to_s).join(" ")
        if args[0..2] == %w[gcloud storage cp] && args.last.to_s.match?(/\.used\.(txt|html)\z/)
          contents[args.last.to_s.end_with?(".used.html") ? :used_html : :used_txt] = File.read(args[-2])
        end
        true
      end
      [commands, contents]
    end

    it "uploads mp3/used/used.html/transcript and writes archives/index/feed/manifest via gcloud storage, without a real gcloud" do
      publisher = described_class.new(date: Date.new(2026, 7, 14))
      commands, contents = stub_gcloud_for_first_publish(publisher)

      publisher.run(mp3_path, used_path, transcript_path)

      expect(Open3).to have_received(:capture3).with("gcloud", "storage", "ls", a_string_matching(/archives\.csv/))
      expect(commands).to include(a_string_matching(/#{Regexp.escape(File.basename(mp3_path))}/))
      expect(commands).to include(a_string_matching(/archives\.csv/))
      expect(commands).to include(a_string_matching(/index\.html/))
      expect(commands).to include(a_string_matching(/feed\.xml/))
      expect(commands).to include(a_string_matching(/manifest\.json/))
      expect(commands).to include(a_string_matching(/used\.html/))
      expect(contents[:used_html]).to include('<div class="news-cat">生成AI</div>')
    end

    it "aborts before any gcloud storage operation when used_news fails validation and repair" do
      publisher = described_class.new(date: Date.new(2026, 7, 14))
      File.write(used_path, "・タイトルだけの旧フォーマット\nhttps://example.com/a\n")
      allow(UsedNewsFormatter).to receive(:run_fix_cli).and_return(nil) # 修復も失敗
      commands = []
      allow(publisher).to receive(:system) do |*args, **_opts|
        commands << args.map(&:to_s).join(" ")
        true
      end

      expect { publisher.run(mp3_path, used_path, transcript_path) }.to raise_error(SystemExit)
      expect(commands).to be_empty # mp3 含め何もアップロードされていない
    end

    it "does not validate used_news when used_txt_path is nil (no used news for this episode)" do
      publisher = described_class.new(date: Date.new(2026, 7, 14))
      _commands, = stub_gcloud_for_first_publish(publisher)
      allow(UsedNewsFormatter).to receive(:ensure_valid!)

      publisher.run(mp3_path, nil, transcript_path)

      expect(UsedNewsFormatter).not_to have_received(:ensure_valid!)
    end
  end

  describe "#upload_content" do
    let(:publisher) { described_class.new(bucket: "test-bucket") }

    it "passes gcloud a cp invocation with the content-type and the tempfile that holds the content" do
      captured = nil
      written = nil
      allow(publisher).to receive(:system) do |*args, **_opts|
        captured = args
        # gcloud に渡す直前の一時ファイルの中身を確認する（cp 先ではなく cp 元）。
        written = File.read(args[-2])
        true
      end

      publisher.send(:upload_content, "feed.xml", "<feed/>", content_type: "application/atom+xml; charset=utf-8")

      expect(captured[0, 3]).to eq(%w[gcloud storage cp])
      expect(captured).to include("--content-type=application/atom+xml; charset=utf-8")
      expect(captured.last).to eq("gs://test-bucket/feed.xml")
      expect(written).to eq("<feed/>")
    end

    it "adds --cache-control only when given" do
      with_cc = nil
      without_cc = nil
      allow(publisher).to receive(:system) do |*args, **_opts|
        with_cc.nil? ? (with_cc = args) : (without_cc = args)
        true
      end

      publisher.send(:upload_content, "index.html", "<html/>",
        content_type: "text/html; charset=utf-8", cache_control: "public, max-age=300")
      publisher.send(:upload_content, "manifest.json", "{}",
        content_type: "application/manifest+json; charset=utf-8")

      expect(with_cc).to include("--cache-control=public, max-age=300")
      expect(without_cc.none? { |a| a.start_with?("--cache-control") }).to be true
    end

    it "removes the tempfile after upload (no leftover)" do
      tempfile_path = nil
      allow(publisher).to receive(:system) do |*args, **_opts|
        tempfile_path = args[-2]
        true
      end

      publisher.send(:upload_content, "manifest.json", "{}", content_type: "application/manifest+json")

      expect(tempfile_path).not_to be_nil
      expect(File.exist?(tempfile_path)).to be false
    end
  end

  describe "#run with retention_episodes" do
    # spec/fixtures/config.yaml の gcs.retention_episodes: 5 を前提に、
    # 既存 archives.csv へ 5 件の過去回を仕込み、保持件数超過分が
    # archived/ へ退避されることを検証する。
    let(:existing_rows) do
      (1..5).map do |n|
        date = Date.new(2026, 6, 1) + n
        fname = "miyamai_news_#{date.strftime('%Y%m%d')}_morning.mp3"
        [date.to_s, fname, "宮舞モカの技術ニュース #{date}", "", "#{date}T00:00:00Z"]
      end
    end
    let(:oldest_fname) { existing_rows.first[1] }

    def stub_archives_exist(exists: true)
      status = instance_double(Process::Status, success?: exists)
      err = exists ? "" : "One or more URLs matched no objects."
      allow(Open3).to receive(:capture3).and_return(["", err, status])
    end

    def stub_gcloud_with_existing_archives(publisher, existing_rows)
      stub_archives_exist(exists: true)
      commands = []
      allow(publisher).to receive(:system) do |*args, **_opts|
        commands << args.map(&:to_s).join(" ")

        # fetch_existing_archives の `cp gs://.../archives.csv <local_csv>` 呼び出しを
        # 検知し、ダウンロード先の一時ファイルへ既存台帳を書き込んでおく。
        if args[0..2] == ["gcloud", "storage", "cp"] && args[3].to_s.end_with?("archives.csv")
          CSV.open(args[4], "w") { |csv| existing_rows.each { |r| csv << r } }
        end

        true
      end
      commands
    end

    it "moves episodes beyond the retention limit to archived/ and drops them from archives.csv" do
      publisher = described_class.new(date: Date.new(2026, 7, 14))
      commands = stub_gcloud_with_existing_archives(publisher, existing_rows)

      publisher.run(mp3_path, used_path, transcript_path)

      expect(commands).to include(a_string_matching(/gcloud storage mv gs:\S*#{Regexp.escape(oldest_fname)} gs:\S*archived\/#{Regexp.escape(oldest_fname)}/))
      expect(commands).to include(a_string_matching(/gcloud storage mv gs:\S*#{Regexp.escape(oldest_fname.sub(/\.mp3\z/, '.used.txt'))} gs:\S*archived\//))
      expect(commands).to include(a_string_matching(/gcloud storage mv gs:\S*#{Regexp.escape(oldest_fname.sub(/\.mp3\z/, '.transcript.txt'))} gs:\S*archived\//))
    end

    it "does not move anything when within the retention limit" do
      publisher = described_class.new(date: Date.new(2026, 7, 14))
      stub_archives_exist(exists: false)
      commands = []

      allow(publisher).to receive(:system) do |*args, **_opts|
        commands << args.map(&:to_s).join(" ")
        true
      end

      publisher.run(mp3_path, used_path, transcript_path)

      expect(commands).not_to include(a_string_matching(/gcloud storage mv/))
    end

    it "aborts instead of overwriting the ledger when checking for it hits a transient gcloud failure" do
      publisher = described_class.new(date: Date.new(2026, 7, 14))
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(["", "gcloud crashed: connection reset", status])
      allow(publisher).to receive(:system).and_return(true)

      expect { publisher.run(mp3_path, used_path, transcript_path) }.to raise_error(/transient failure/)
      expect(publisher).not_to have_received(:system).with(*%w[gcloud storage cp], a_string_matching(/archives\.csv/))
    end
  end

  describe "#clean_archive" do
    let(:publisher) { described_class.new }
    let(:success_status) { instance_double(Process::Status, success?: true) }
    let(:failure_status) { instance_double(Process::Status, success?: false) }

    it "deletes everything under archived/ via gcloud storage rm" do
      allow(Open3).to receive(:capture3).and_return(["", "", success_status])

      publisher.clean_archive

      expect(Open3).to have_received(:capture3).with(
        "gcloud", "storage", "rm", "--recursive", a_string_matching(%r{gs://\S*/archived/})
      )
    end

    it "does not abort when archived/ is empty (no matching objects)" do
      err = "ERROR: (gcloud.storage.rm) The following URLs matched no objects or files:\n"
      allow(Open3).to receive(:capture3).and_return(["", err, failure_status])

      expect { publisher.clean_archive }.not_to raise_error
    end

    it "aborts on a transient gcloud failure instead of reporting success" do
      err = "ERROR: gcloud crashed (ProxyError): Max retries exceeded\n"
      allow(Open3).to receive(:capture3).and_return(["", err, failure_status])

      expect { publisher.clean_archive }.to raise_error(SystemExit)
    end
  end

  describe "#render_feed_entry" do
    let(:publisher) { described_class.new(date: Date.new(2026, 7, 14)) }

    def content_of(xml)
      xml[%r{<content type="html">(.*)</content>}m, 1]
    end

    def render(used_news)
      xml = publisher.send(:render_feed_entry, "2026-07-14", "miyamai_news_20260714_morning.mp3",
        "宮舞モカの技術ニュース", used_news, "2026-07-14T00:00:00Z")
      content_of(xml)
    end

    # 新フォーマット（## カテゴリ / ### [タイトル](URL)）は構造化 HTML になる。
    context "with the new Markdown format" do
      let(:used_news) do
        <<~USED
          ## 生成AI
          ### [Gemini 3.5 Pro が延期か](https://example.com/gemini)
             次世代 LLM の開発が難航しているという観測。
             (2026-07-17 / 財経新聞)
        USED
      end

      it "renders structured HTML with the title linked, surviving both decode steps" do
        xml_decoded = CGI.unescapeHTML(render(used_news))

        expect(xml_decoded).to include('<div class="news-cat">生成AI</div>')
        expect(xml_decoded).to include(
          '<div class="news-title"><a href="https://example.com/gemini" target="_blank" rel="noopener">Gemini 3.5 Pro が延期か</a></div>'
        )
        expect(xml_decoded).to include('<div class="news-meta">(2026-07-17 / 財経新聞)</div>')
      end

      it "escapes markup in the source text so it does not become real tags" do
        malicious = "## 生成AI\n### [<dialog>要素](https://example.com/a)\n   本文\n"
        xml_decoded = CGI.unescapeHTML(render(malicious))

        expect(xml_decoded).to include("&lt;dialog&gt;")
        expect(xml_decoded).not_to include("<dialog>")
      end
    end

    # 旧フォーマット・崩れ（## 見出しが無い）は生テキスト整形へフォールバックする。
    context "with the old/unparseable format (fallback path)" do
      it "escapes used_news so it survives XML-decode-then-HTML-parse without becoming markup" do
        xml_decoded = CGI.unescapeHTML(render("・<dialog>要素の新機能\n   https://example.com/a\n"))

        expect(xml_decoded).to include("&lt;dialog&gt;")
        expect(xml_decoded).not_to include("<dialog>")
      end

      it "preserves line breaks as <br> after both decode steps" do
        xml_decoded = CGI.unescapeHTML(render("1行目\n2行目\n"))

        expect(xml_decoded).to include("1行目<br>")
        expect(xml_decoded).to include("2行目<br>")
      end

      it "turns URLs into anchor tags after both decode steps" do
        xml_decoded = CGI.unescapeHTML(render("参考: https://example.com/a\n"))

        expect(xml_decoded).to include('<a href="https://example.com/a">https://example.com/a</a>')
      end
    end

    it "leaves content empty when used_news is blank" do
      expect(render("")).to eq("")
    end
  end

  describe ".episode_object_names" do
    it "expands an mp3 filename to all sibling files that make up one episode" do
      names = described_class.episode_object_names("miyamai_news_20260714_afternoon.mp3")

      expect(names).to eq([
        "miyamai_news_20260714_afternoon.mp3",
        "miyamai_news_20260714_afternoon.used.txt",
        "miyamai_news_20260714_afternoon.transcript.txt"
      ])
    end
  end

  describe "#render_html and #render_feed" do
    # 番組名を PROGRAM_NAME の実値と別の文字列に差し替えて描画する。テンプレートが
    # 定数を参照せずリテラルをハードコードしていると、この値が反映されず検出できる。
    let(:program_name) { "テスト番組名XYZ" }
    let(:publisher) { described_class.new(date: Date.new(2026, 7, 14)) }
    let(:rows) do
      [["2026-07-14", "miyamai_news_20260714_afternoon.mp3", "回タイトル 2026-07-14", "", "2026-07-14T00:00:00Z"]]
    end

    before { stub_const("Publisher::PROGRAM_NAME", program_name) }

    it "renders PROGRAM_NAME into index.html's <title>/<link title>/<h1> instead of a hardcoded string" do
      html = publisher.send(:render_html, rows)

      expect(html).to include("<title>#{program_name}</title>")
      expect(html).to include(%(title="#{program_name}"))
      expect(html).to include("<h1>#{program_name}</h1>")
    end

    it "renders PROGRAM_NAME into feed.xml's <title> instead of a hardcoded string" do
      xml = publisher.send(:render_feed, rows)

      expect(xml).to include("<title>#{program_name}</title>")
    end
  end

  describe "#object_exists?" do
    let(:publisher) { described_class.new }
    let(:success_status) { instance_double(Process::Status, success?: true) }
    let(:failure_status) { instance_double(Process::Status, success?: false) }

    it "returns true when gcloud storage ls succeeds" do
      allow(Open3).to receive(:capture3).and_return(["", "", success_status])

      expect(publisher.object_exists?("foo.mp3")).to be true
      expect(Open3).to have_received(:capture3).with(
        "gcloud", "storage", "ls", a_string_matching(%r{gs://.*/foo\.mp3})
      )
    end

    it "returns false when gcloud reports no matching objects (genuine absence)" do
      err = "ERROR: (gcloud.storage.ls) One or more URLs matched no objects.\n"
      allow(Open3).to receive(:capture3).and_return(["", err, failure_status])

      expect(publisher.object_exists?("foo.mp3")).to be false
    end

    it "raises instead of returning false on a transient gcloud failure" do
      err = "ERROR: (gcloud.storage.ls) Your current active account does not have any valid credentials\n"
      allow(Open3).to receive(:capture3).and_return(["", err, failure_status])

      expect { publisher.object_exists?("foo.mp3") }.to raise_error(/transient failure/)
    end

    it "raises a descriptive error when gcloud itself is not installed" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT.new("gcloud"))

      expect { publisher.object_exists?("foo.mp3") }.to raise_error(/gcloud not found/)
    end
  end
end
