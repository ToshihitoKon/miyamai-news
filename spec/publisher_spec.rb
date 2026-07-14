# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "date"
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
