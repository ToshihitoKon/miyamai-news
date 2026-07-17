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
    File.write(used_path, "1. Title A\nhttps://example.com/a\n")
    File.write(transcript_path, "宮舞モカです。\n")
  end

  after { FileUtils.remove_entry(work_dir) }

  describe "#run" do
    it "uploads mp3/used/transcript and writes archives/index/feed/manifest via gcloud storage, without a real gcloud" do
      publisher = described_class.new(date: Date.new(2026, 7, 14))
      commands = []

      allow(publisher).to receive(:system) do |*args, **_opts|
        joined = args.map(&:to_s).join(" ")
        commands << joined
        # 初回公開シナリオ: archives.csv はまだ GCS に存在しない
        joined.include?(" ls ") ? false : true
      end

      publisher.run(mp3_path, used_path, transcript_path)

      expect(commands).to include(a_string_matching(%r{gcloud storage ls gs://.*archives\.csv}))
      expect(commands).to include(a_string_matching(/#{Regexp.escape(File.basename(mp3_path))}/))
      expect(commands).to include(a_string_matching(/archives\.csv/))
      expect(commands).to include(a_string_matching(/index\.html/))
      expect(commands).to include(a_string_matching(/feed\.xml/))
      expect(commands).to include(a_string_matching(/manifest\.json/))
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

    def stub_gcloud_with_existing_archives(publisher, existing_rows)
      commands = []
      allow(publisher).to receive(:system) do |*args, **_opts|
        joined = args.map(&:to_s).join(" ")
        commands << joined

        # fetch_existing_archives の `cp gs://.../archives.csv <local_csv>` 呼び出しを
        # 検知し、ダウンロード先の一時ファイルへ既存台帳を書き込んでおく。
        if args[0..2] == ["gcloud", "storage", "cp"] && args[3].to_s.end_with?("archives.csv")
          CSV.open(args[4], "w") { |csv| existing_rows.each { |r| csv << r } }
        end

        !joined.include?(" ls ") || joined.include?("archives.csv")
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
      commands = []

      allow(publisher).to receive(:system) do |*args, **_opts|
        joined = args.map(&:to_s).join(" ")
        commands << joined
        joined.include?(" ls ") ? false : true
      end

      publisher.run(mp3_path, used_path, transcript_path)

      expect(commands).not_to include(a_string_matching(/gcloud storage mv/))
    end
  end

  describe "#clean_archive" do
    it "deletes everything under archived/ via gcloud storage rm" do
      publisher = described_class.new
      allow(publisher).to receive(:system).and_return(true)

      publisher.clean_archive

      expect(publisher).to have_received(:system).with(a_string_matching(%r{gcloud storage rm --recursive gs://\S*/archived/}))
    end
  end

  describe "#render_feed_entry" do
    let(:publisher) { described_class.new(date: Date.new(2026, 7, 14)) }

    def content_of(xml)
      xml[%r{<content type="html">(.*)</content>}m, 1]
    end

    it "escapes used_news so it survives XML-decode-then-HTML-parse without becoming markup" do
      used_news = "・<dialog>要素の新機能\n   https://example.com/a\n"

      xml = publisher.send(:render_feed_entry, "2026-07-14", "miyamai_news_20260714_morning.mp3",
        "宮舞モカの技術ニュース", used_news, "2026-07-14T00:00:00Z")
      content = content_of(xml)

      # XML デコードしても <dialog> が実タグとして残らないこと
      # （h() が一段のみだと &lt;dialog&gt; まで戻り、リーダー側で実タグ化してしまう）。
      xml_decoded = CGI.unescapeHTML(content)
      expect(xml_decoded).to include("&lt;dialog&gt;")
      expect(xml_decoded).not_to include("<dialog>")
    end

    it "preserves line breaks as <br> after both decode steps" do
      used_news = "1行目\n2行目\n"

      xml = publisher.send(:render_feed_entry, "2026-07-14", "miyamai_news_20260714_morning.mp3",
        "宮舞モカの技術ニュース", used_news, "2026-07-14T00:00:00Z")
      xml_decoded = CGI.unescapeHTML(content_of(xml))

      expect(xml_decoded).to include("1行目<br>")
      expect(xml_decoded).to include("2行目<br>")
    end

    it "turns URLs into anchor tags after both decode steps" do
      used_news = "参考: https://example.com/a\n"

      xml = publisher.send(:render_feed_entry, "2026-07-14", "miyamai_news_20260714_morning.mp3",
        "宮舞モカの技術ニュース", used_news, "2026-07-14T00:00:00Z")
      xml_decoded = CGI.unescapeHTML(content_of(xml))

      expect(xml_decoded).to include('<a href="https://example.com/a">https://example.com/a</a>')
    end

    it "leaves content empty when used_news is blank" do
      xml = publisher.send(:render_feed_entry, "2026-07-14", "miyamai_news_20260714_morning.mp3",
        "宮舞モカの技術ニュース", "", "2026-07-14T00:00:00Z")

      expect(content_of(xml)).to eq("")
    end
  end

  describe "#object_exists?" do
    it "delegates to `gcloud storage ls`" do
      publisher = described_class.new
      allow(publisher).to receive(:system).and_return(true)

      expect(publisher.object_exists?("foo.mp3")).to be true
      expect(publisher).to have_received(:system).with(
        "gcloud", "storage", "ls", a_string_matching(%r{gs://.*/foo\.mp3}),
        out: File::NULL, err: File::NULL
      )
    end
  end
end
